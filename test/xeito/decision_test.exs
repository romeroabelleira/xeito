defmodule Xeito.DecisionTest do
  use ExUnit.Case, async: true

  alias Xeito.Decider
  alias Xeito.Decision
  alias Xeito.Decision.Eval
  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Scoring
  alias Xeito.Decision.Type
  alias Xeito.Decisions.Risk
  alias Xeito.Decisions.Triage

  defp compile(body) do
    name = "Xeito.DecisionTest.D#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{name} do
      use Xeito.Decision, version: "1"
      #{body}
    end
    """)
  end

  describe "DSL" do
    test "compiles a type with inputs, values, rules and severity" do
      type = Decision.type!(Risk)
      assert type.name == "risk"
      assert Type.values(type) == [:safe, :review, :forbidden]
      assert type.severity == %{order: [:safe, :review, :forbidden], floor: :review}
      assert [%{name: :command, max_bytes: 1_000}, %{name: :cwd, required: false}] = type.inputs
    end

    test "rejects invalid types" do
      error =
        assert_raise CompileError, fn ->
          compile("""
          input :x
          value :abstain, "no"
          rule :missing, then: :nope
          """)
        end

      assert error.description =~ "`instructions` is required"
      assert error.description =~ "at least two values"
      assert error.description =~ "`:abstain` is implicit"
      assert error.description =~ "rule missing/1 must be a public function"
    end
  end

  describe "Type" do
    test "normalises and truncates inputs deterministically" do
      type = Decision.type!(Triage)
      long = String.duplicate("x", 5_000) <> "END"
      input = Type.normalize_input(type, %{test: "t", output: long})

      assert byte_size(input.output) == 3_000 and String.ends_with?(input.output, "END")
      assert input.diff_stat == ""
      assert Type.input_hash(type, input) == Type.input_hash(type, input)

      assert_raise ArgumentError, ~r/missing required input :test/, fn ->
        Type.normalize_input(type, %{output: "o"})
      end
    end

    test "casts model strings to values only" do
      type = Decision.type!(Triage)
      assert {:ok, :flaky} = Type.cast(type, "flaky")
      assert :error = Type.cast(type, "delete_everything")
    end
  end

  describe "Prompt" do
    test "the JSON schema is a closed enum with the value first and no rationale" do
      schema = Prompt.json_schema(Decision.type!(Triage))
      assert Map.keys(schema["properties"]) == ["value"]

      assert schema["properties"]["value"]["enum"] == [
               "flaky",
               "code_bug",
               "test_bug",
               "env_problem"
             ]

      assert schema["additionalProperties"] == false
    end

    test "system_one requests pin the model and name the question after the type" do
      body =
        Prompt.system_one(
          Decision.type!(Triage),
          %{test: "t", output: "o", diff_stat: ""},
          "multilingual"
        )

      assert body["model"] == "multilingual"

      assert %{"triage" => %{"type" => "choice", "criteria" => %{"flaky" => _}}} =
               body["questions"]
    end
  end

  describe "Scoring" do
    test "assigns mass by prefix and ignores tokens the grammar would forbid" do
      tops = [
        {"env", :math.log(0.5)},
        {"code", :math.log(0.3)},
        {"The", :math.log(0.15)},
        {"fl", :math.log(0.05)}
      ]

      probs =
        tops
        |> Scoring.assign(["flaky", "code_bug", "test_bug", "env_problem"])
        |> Map.fetch!(:probs)
        |> Scoring.normalize()

      assert_in_delta probs["env_problem"], 0.5 / 0.85, 1.0e-9
      assert_in_delta probs["flaky"], 0.05 / 0.85, 1.0e-9
      refute Map.has_key?(probs, "test_bug")
    end

    test "reports tokens that start several options as ambiguous" do
      %{probs: probs, ambiguous: [amb]} =
        Scoring.assign([{" test", 0.0}], ["test_bug", "test_flaky", "code"])

      assert probs == %{}
      assert amb.options == ["test_bug", "test_flaky"]

      assert Scoring.one_step([{"test", 0.0}], ["test_bug", "test_flaky"]) == %{
               "test_bug" => 0.5,
               "test_flaky" => 0.5
             }
    end

    test "an ended option matches a closing quote" do
      assert %{probs: %{"" => _}} = Scoring.assign([{"\"}", 0.0}], ["", "_bug"])
    end
  end

  describe "Risk rules" do
    test "block every command in the dangerous set" do
      dangerous = Risk |> Eval.examples() |> Enum.filter(& &1.dangerous)
      assert length(dangerous) >= 40

      missed =
        for ex <- dangerous,
            Decider.apply_rules(
              Decision.type!(Risk),
              Type.normalize_input(Decision.type!(Risk), ex.input)
            ) !=
              {:ok, :forbidden, :classify},
            do: ex.input.command

      assert missed == []
    end

    test "never classify a labelled review command as safe" do
      type = Decision.type!(Risk)

      unsafe_as_safe =
        for ex <- Eval.examples(Risk),
            ex.label != :safe,
            {:ok, :safe, _} <- [Decider.apply_rules(type, Type.normalize_input(type, ex.input))],
            do: ex.input.command

      assert unsafe_as_safe == []
    end

    test "read-only commands are safe by rule, quotes and harmless redirects included" do
      type = Decision.type!(Risk)

      missed =
        for ex <- Eval.examples(Risk),
            ex.label == :safe and ex.source == "dogfood",
            Decider.apply_rules(type, Type.normalize_input(type, ex.input)) !=
              {:ok, :safe, :classify},
            do: ex.input.command

      assert missed == []
    end

    test "the shell tokenizer splits on unquoted operators only" do
      assert Risk.segments(~s(grep -n "a\\|b" f 2>/dev/null | head -3; echo "x; y")) ==
               {:ok, [~s(grep -n "a\\|b" f), "head -3", ~s(echo "x; y")]}

      assert Risk.segments("mix test 2>&1 | tail") == {:ok, ["mix test", "tail"]}
      assert Risk.segments("echo '$(not run)' && ls") == {:ok, ["echo '$(not run)'", "ls"]}

      for unsafe <- ["ls > out", ~s(echo "`id`"), "ls & rm x", "echo 'open", "cat <<EOF"] do
        assert Risk.segments(unsafe) == :unsafe, unsafe
      end
    end

    test "the tokenizer also splits on || and newlines, keeps escapes, and drops harmless redirects" do
      assert Risk.segments("ls || echo none") == {:ok, ["ls", "echo none"]}
      assert Risk.segments("ls\nrm -rf build") == {:ok, ["ls", "rm -rf build"]}
      assert Risk.segments(~S(echo "a\"; b" \; c)) == {:ok, [~S(echo "a\"; b" \; c)]}

      for quiet <- ["mix test &>/dev/null", "mix test >>/dev/null", "ls 1>/dev/null", "ls 0>/dev/null"],
          do: assert(Risk.segments(quiet) == {:ok, [quiet |> String.split(~r/\s*\d?&?>/) |> hd()]}, quiet)
    end

    defp risk(command), do: Risk.classify(%{command: command})

    test "every segment counts: a safe first command does not cover the next line" do
      assert risk("ls\nrm -rf build") == nil
    end

    test "forbidden: deleting the root without its guard, and wiping history before deleting" do
      assert risk("rm --no-preserve-root -rf /") == :forbidden
      assert risk("history -c && rm -rf ~/.bash_history") == :forbidden
    end

    # The allowlist, spelled out: changing what counts as safe should change a test.
    @safe_by_rule [
      "ls -la",
      "cat a.ex",
      "head -5 a",
      "tail -5 a",
      "grep -rn x lib",
      "rg x",
      "pwd",
      "echo hi",
      "wc -l a",
      "which mix",
      "tree lib",
      "stat a",
      "du -sh .",
      "df -h",
      "diff a b",
      "less a",
      "file a",
      "sort a",
      "uniq a",
      "cut -d, -f1 a",
      "git status",
      "git diff HEAD",
      "git log --oneline",
      "git show HEAD",
      "git branch -a",
      "git blame a.ex",
      "mix test",
      "mix compile",
      "mix format --check-formatted",
      "mix deps.get",
      "mix credo --strict",
      "npm test",
      "npm run test",
      "npm run lint",
      "pytest -q",
      "python -m pytest",
      "python3 -m pytest",
      "cargo test",
      "cargo build",
      "cargo check",
      "go test ./...",
      "go build ./...",
      "make test",
      "bundle exec rspec"
    ]

    test "the commands and prefixes that are safe by rule" do
      assert Enum.reject(@safe_by_rule, &(risk(&1) == :safe)) == []
    end

    test "never safe: allowlisted commands that delete, execute, force, or touch secrets" do
      for command <- [
            "find . -name '*.beam' -delete",
            ~S(find . -name x -exec rm {} \;),
            "find . -fls out.txt",
            "git branch --force main HEAD~1",
            "cat ~/.ssh/id_rsa",
            "cat ~/.aws/credentials",
            "cat ~/.netrc",
            "cat .env"
          ],
          do: assert(risk(command) == nil, command)
    end

    test "the decider raises model output to the floor" do
      decision = Decider.decide(Risk, %{command: "some-unknown-tool --flag"}, deciders: [])
      assert %Decision{value: :review, actor: :none} = decision
    end
  end

  test "Risk.written_paths/1: the literal paths a command writes, as written, or :error" do
    assert Risk.written_paths("sed -i 's/a/b/' /etc/x.conf notes.txt") == {:ok, ["/etc/x.conf", "notes.txt"]}
    assert Risk.written_paths("echo hi > /tmp/out.txt && touch a b") == {:ok, ["/tmp/out.txt", "a", "b"]}
    assert Risk.written_paths("ls -la | grep x") == {:ok, []}

    for unknown <- ["cp $X y", "cd /tmp && touch x", "make", "touch ~/x", "echo $(id) > f"],
        do: assert(Risk.written_paths(unknown) == :error, unknown)
  end

  describe "Risk: writes inside the workspace" do
    setup do
      root = Path.join(System.tmp_dir!(), "xeito-risk-#{System.unique_integer([:positive])}")
      ws = Path.join(root, "ws")
      outside = Path.join(root, "outside")
      for dir <- [Path.join(ws, "lib"), Path.join(ws, ".git"), outside], do: File.mkdir_p!(dir)
      File.write!(Path.join(ws, "a.txt"), "x")
      File.ln_s!(outside, Path.join(ws, "out_dir"))
      File.ln_s!(Path.join(outside, "f"), Path.join(ws, "out_file"))
      File.ln_s!("loop", Path.join(ws, "loop"))
      on_exit(fn -> File.rm_rf(root) end)
      %{ws: ws}
    end

    defp write_risk(command, ws), do: Risk.classify(%{command: command, cwd: ws})

    test "redirects, tee and file commands whose targets stay inside are safe", %{ws: ws} do
      for command <- [
            "echo hi > out.txt",
            "mix test > test.log 2>&1",
            "ls >> notes/list.txt",
            "mix compile 2> errors.txt",
            "mix test &> all.log",
            "grep -rn TODO lib | tee todo.txt",
            "tee -a log.txt",
            "touch a.txt b.txt",
            "mkdir -p tmp/x",
            "rm -rf tmp",
            "rm a.txt",
            "mv a.txt b.txt",
            "cp -r lib lib2",
            "cp 'a.txt' 'with space.txt'",
            "ls > out.txt && cat out.txt"
          ],
          do: assert(write_risk(command, ws) == :safe, command)
    end

    test "sed -i with one plain substitution is safe; scripts that could write or run something are not", %{ws: ws} do
      for command <- [
            "sed -i 's/foo/bar/g' lib/a.ex",
            "sed -i '' 's|a|b|' a.txt",
            "sed -i.bak -e 's/a/b/' a.txt",
            "sed -E -i 's/a+/b/2' a.txt",
            "sed -r -i 's/a+/b/' a.txt"
          ],
          do: assert(write_risk(command, ws) == :safe, command)

      for command <- [
            "sed -i 's/a/b/w /tmp/x' a.txt",
            "sed -i 's/a/b/;e id' a.txt",
            "sed -i 's/a/b/e' a.txt",
            ~S(sed -i "s/$X/y/" a.txt),
            "sed 's/a/b/' a.txt > a.txt.new && sed -i 1d a.txt",
            "sed -i 's/a/b/'",
            "sed -i 's/a/b/' -z a.txt",
            "sed -n 's/a/b/' a.txt > x.txt && sed --in-place 's/a/b/' a.txt"
          ],
          do: assert(write_risk(command, ws) == nil, command)
    end

    test "a target outside, at the root, in .git or a protected directory, or not literal is not safe", %{ws: ws} do
      for command <- [
            "echo x > ../x",
            "echo x > /tmp/x",
            "echo x > ~/x",
            "echo x > *.txt",
            "echo x >'q.txt'",
            "echo x > $HOME/x",
            "echo x > out_dir/x",
            "echo x > out_file",
            "touch out_dir",
            "echo x > loop/x",
            "rm -rf .",
            "rm -rf ./",
            "rm -rf .git",
            "rm lib/../.git/config",
            "touch .git/x",
            "touch deps/x",
            "echo x > _build/x",
            "touch node_modules/x",
            "touch .xeito/x",
            "cp a.txt /tmp/",
            "mv a.txt ../b",
            "rm *.txt",
            ~S(echo x > "my file"),
            "rm -r -- a.txt",
            "cp --target-directory=/tmp a.txt",
            "rm",
            "cd lib && echo x > a.txt",
            "chmod 644 a.txt",
            "cp .env env.txt",
            "find . -name x | xargs rm"
          ],
          do: assert(write_risk(command, ws) == nil, command)
    end

    test "without a workspace, no write is safe; forbidden stays forbidden", %{ws: ws} do
      assert Risk.classify(%{command: "echo hi > out.txt"}) == nil
      assert Risk.classify(%{command: "echo hi > out.txt", cwd: ""}) == nil
      assert write_risk("rm -rf /", ws) == :forbidden
    end

    test "the tokenizer still calls a file redirect unsafe for read-only use" do
      assert Risk.segments("ls > out") == :unsafe

      assert Risk.parse("ls -la > out.txt | tee b && echo x 2>/dev/null") ==
               {:ok, ["ls -la", "tee b", "echo x"], ["out.txt"]}

      assert Risk.parse("echo `id` > x") == :unsafe
    end
  end
end
