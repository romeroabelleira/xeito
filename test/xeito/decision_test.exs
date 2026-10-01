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
      assert [%{name: :command, max_bytes: 1_000}] = type.inputs
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

    test "the decider raises model output to the floor" do
      decision = Decider.decide(Risk, %{command: "some-unknown-tool --flag"}, deciders: [])
      assert %Decision{value: :review, actor: :none} = decision
    end
  end
end
