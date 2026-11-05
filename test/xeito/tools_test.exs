defmodule Xeito.ToolsTest do
  use ExUnit.Case, async: true

  alias Xeito.Effect
  alias Xeito.Tools

  defp effect(name, args, ctx \\ %{cwd: "/w"}), do: Tools.to_effect(%{name: name, arguments: args}, ctx)

  describe "to_effect/2" do
    test "read: a whole file, a symbol, an outline, a line range, or an earlier result" do
      assert {:ok, %Effect{kind: :read, args: %{path: "a.ex", cwd: "/w"}}} = effect("read", %{"path" => "a.ex"})
      assert {:ok, %Effect{args: %{symbol: "f/1"}}} = effect("read", %{"path" => "a.ex", "symbol" => "f/1"})
      assert {:ok, %Effect{args: %{outline: true}}} = effect("read", %{"path" => "a.ex", "outline" => true})
      assert {:ok, %Effect{args: %{lines: "3-9"}}} = effect("read", %{"path" => "a.ex", "lines" => "3-9"})
      assert {:ok, %Effect{args: %{result: "e4"}}} = effect("read", %{"result" => "e4"})
      assert {:ok, %Effect{args: %{path: "a.ex"} = args}} = effect("read", %{"path" => "a.ex", "symbol" => ""})
      refute Map.has_key?(args, :symbol)
    end

    test "write, edit and bash; writes into a protected directory are refused" do
      assert {:ok, %Effect{kind: :write}} = effect("write", %{"path" => "a.ex", "content" => "x"})
      assert {:ok, %Effect{kind: :edit}} = effect("edit", %{"path" => "a.ex", "old_text" => "x", "new_text" => "y"})
      assert {:ok, %Effect{kind: :bash, args: %{cmd: "ls"}}} = effect("bash", %{"command" => "ls"})
      assert {:error, "refused: deps/ " <> _} = effect("write", %{"path" => "deps/x/a.ex", "content" => "x"})

      assert {:error, "refused: .git/ " <> _} =
               effect("edit", %{"path" => ".git/config", "old_text" => "a", "new_text" => "b"})
    end

    test "script: the program is the argument; its time limit is asked for as bash's, with a longer default" do
      assert {:ok, %Effect{kind: :script, args: %{code: "1 + 1", cwd: "/w", timeout: 300_000}, reply: :tool_done}} =
               effect("script", %{"program" => "1 + 1"})

      assert {:ok, %Effect{args: %{timeout: 30_000}}} = effect("script", %{"program" => "1", "timeout_s" => 30})
      assert {:ok, %Effect{args: %{timeout: 600_000}}} = effect("script", %{"program" => "1", "timeout_s" => 9_999})
      assert {:error, "invalid arguments for script" <> _} = effect("script", %{"program" => ""})
      assert {:error, "invalid arguments for script" <> _} = effect("script", %{"code" => "1"})
      refute Tools.risky?(%{name: "script", arguments: %{"program" => "Script.bash(\"rm -rf /\")"}})
      assert [%{function: %{name: "script", description: description}}] = Tools.specs(["script"])
      assert description =~ "Script.read(path) gives {:ok, text} or {:error, reason}"
      assert description =~ "Script.bash(command) gives {:ok, output} when the command exits 0"
      assert description =~ "{:error, %{exit_status: n, output: text}}"

      assert description =~
               ~s|Example:\n{:ok, out} = Script.bash("grep -rln TODO lib/")\nfor file <- String.split(out, "\\n", trim: true) do\n  {:ok, text} = Script.read(file)|
    end

    test "bash takes the timeout the model asks for, in seconds, up to the maximum" do
      timeout = fn args ->
        {:ok, %Effect{args: %{timeout: ms}}} = effect("bash", Map.put(args, "command", "mix test"))
        ms
      end

      assert timeout.(%{}) == 60_000
      assert timeout.(%{"timeout_s" => 300}) == 300_000
      assert timeout.(%{"timeout_s" => 1.5}) == 1_500
      # Small models often send numbers as strings.
      assert timeout.(%{"timeout_s" => "120"}) == 120_000
      assert timeout.(%{"timeout_s" => Tools.max_bash_timeout_s() + 1}) == Tools.max_bash_timeout_s() * 1_000
      # Nonsense is not an error: the default applies.
      for bad <- [0, -5, "soon", nil, true], do: assert(timeout.(%{"timeout_s" => bad}) == 60_000)
    end

    test "the bash tool offers the timeout, and only the command is required" do
      bash = Enum.find(Tools.specs(), &(&1.function.name == "bash"))
      assert bash.function.parameters.required == ["command"]
      assert bash.function.parameters.properties.timeout_s.description =~ "at most #{Tools.max_bash_timeout_s()}"
    end

    test "the skill tool reads files of a skill the run offers, and only then" do
      ctx = %{cwd: "/w", skills: [%{name: "deploy", dir: "/skills/deploy"}]}

      assert {:ok, %Effect{kind: :read, args: %{path: "SKILL.md", cwd: "/skills/deploy"}}} =
               effect("skill", %{"name" => "deploy"}, ctx)

      assert {:ok, %Effect{args: %{path: "ref.md"}}} = effect("skill", %{"name" => "deploy", "file" => "ref.md"}, ctx)
      assert {:error, ~s(no skill named "other")} = effect("skill", %{"name" => "other"}, ctx)
      assert {:error, "unknown tool \"skill\"" <> _} = effect("skill", %{"name" => "deploy"})
    end

    test "bad arguments, an unknown tool, or no tools at all" do
      assert {:error, "invalid arguments for bash: %{}"} = effect("bash", %{})
      assert {:error, "invalid arguments for edit: " <> _} = effect("edit", %{"path" => "a.ex"})
      assert {:error, "invalid arguments for write: " <> _} = effect("write", %{"path" => "a.ex"})
      assert {:error, "invalid arguments for read: " <> _} = effect("read", %{})
      assert {:error, "unknown tool \"fly\"; available: read, write, edit, bash, script"} = effect("fly", %{})

      assert {:error, "no tools are available in this turn; answer in text"} =
               effect("bash", %{"command" => "ls"}, %{tools: false})
    end

    test "write and edit refuse dependencies, build output, git data and the log, not similar names" do
      ctx = %{cwd: "/w"}

      edit = fn path ->
        %{name: "edit", arguments: %{"path" => path, "old_text" => "a", "new_text" => "b"}}
      end

      for path <- [
            "deps/term_ui/lib/x.ex",
            "./_build/dev/x",
            "/w/node_modules/p/i.js",
            ".git/config",
            ".xeito/log.sqlite"
          ] do
        assert {:error, "refused: " <> _} = Tools.to_effect(edit.(path), ctx), path
      end

      assert {:error, "refused: deps/ holds fetched dependencies" <> _} =
               Tools.to_effect(
                 %{name: "write", arguments: %{"path" => "deps/x", "content" => ""}},
                 ctx
               )

      # Similar names elsewhere are the project's own files.
      for path <- ["lib/deps/x.ex", "deps.md", "src/_build.ts"] do
        assert {:ok, _} = Tools.to_effect(edit.(path), ctx), path
      end
    end
  end

  test "result_text/1: what the model is told about each kind of result" do
    assert Tools.result_text(%{shaped: "short", exit_status: 0, output: "long"}) == "short"
    assert Tools.result_text(%{exit_status: 1, output: "boom"}) == "exit status 1\nboom"

    # A command stopped at its timeout says how to give it longer.
    assert Tools.result_text(%{exit_status: 124, output: "half", timed_out: true}) ==
             "exit status 124\nhalf\nIf it needs longer, run it again with timeout_s " <>
               "(seconds, at most #{Tools.max_bash_timeout_s()})."

    assert Tools.result_text(%{shaped: "short", exit_status: 124, output: "long", timed_out: true}) =~
             ~r/\Ashort\nIf it needs longer/

    assert Tools.result_text(%{ok: true, content: "text"}) == "text"
    assert Tools.result_text(%{ok: true, syntax_error: "line 3"}) =~ "the file no longer parses: line 3"
    assert Tools.result_text(%{ok: true}) == "ok"
    assert Tools.result_text(%{ok: false, error: "missing"}) == "error: missing"
    assert Tools.result_text(%{ok: false, error: :enoent}) == "error: :enoent"
    assert Tools.result_text(%{something: 1}) == "%{something: 1}"
  end

  describe "direct MCP tools (ctx.mcp)" do
    defp mcp(name, annotations),
      do: %{
        server: "fx",
        name: name,
        description: "does #{name}",
        schema: %{"type" => "object"},
        annotations: annotations,
        exposure: :direct
      }

    defp echo, do: mcp("echo", %{"readOnlyHint" => true, "openWorldHint" => false})
    defp wipe, do: mcp("wipe", %{"destructiveHint" => true, "openWorldHint" => false})
    defp lookup, do: mcp("lookup", %{"readOnlyHint" => true, "openWorldHint" => true})

    test "are offered as server__tool, with their specs beside the names, and only those listed when tools are" do
      ctx = %{cwd: "/w", mcp: [echo(), wipe()]}
      assert Tools.names_for(ctx) == ~w(read write edit bash script fx__echo fx__wipe)
      assert %{ctx | mcp: [echo()]} |> Map.put(:tools, ~w(read fx__echo)) |> Tools.names_for() == ~w(read fx__echo)

      offered = Tools.offered(ctx)
      assert ~w(read write edit bash script fx__echo fx__wipe) = Enum.filter(offered, &is_binary/1)

      assert [%{function: %{name: "fx__echo", description: "does echo"}}, %{function: %{name: "fx__wipe"}}] =
               Enum.filter(offered, &is_map/1)

      assert [%{function: %{name: "read"}}, %{function: %{name: "fx__echo"}}] =
               Tools.specs(["read", Xeito.Mcp.Tool.spec(echo())])
    end

    test "a call becomes an mcp effect with what the rules decide; an open-world tool needs the network setting" do
      ctx = %{cwd: "/w", mcp: [echo(), wipe(), lookup()], network: :forbidden}

      assert {:ok,
              %Effect{
                kind: :mcp,
                args: %{server: "fx", tool: "echo", args: %{"text" => "x"}, cwd: "/w", risk: :safe},
                reply: :tool_done
              }} =
               Tools.to_effect(%{name: "fx__echo", arguments: %{"text" => "x"}}, ctx)

      assert {:ok, %Effect{args: %{risk: :review}}} = Tools.to_effect(%{name: "fx__wipe", arguments: %{}}, ctx)

      assert {:error, "refused: fx__lookup reaches outside" <> _} =
               Tools.to_effect(%{name: "fx__lookup", arguments: %{}}, ctx)

      assert {:ok, %Effect{kind: :mcp}} =
               Tools.to_effect(%{name: "fx__lookup", arguments: %{}}, %{ctx | network: :allowed})

      assert {:error, "invalid arguments for fx__echo" <> _} = Tools.to_effect(%{name: "fx__echo", arguments: "x"}, ctx)
      assert {:error, "unknown tool \"fx__nope\"" <> _} = Tools.to_effect(%{name: "fx__nope", arguments: %{}}, ctx)
    end

    test "gate/2: bash goes to the Risk decision, a tool safe by rule runs, any other MCP tool goes to a human" do
      ctx = %{cwd: "/w", mcp: [echo(), wipe()]}
      assert Tools.gate(%{name: "bash", arguments: %{"command" => "ls"}}, ctx) == :risk
      assert Tools.gate(%{name: "read", arguments: %{"path" => "a"}}, ctx) == :run
      assert Tools.gate(%{name: "fx__echo", arguments: %{}}, ctx) == :run
      assert Tools.gate(%{name: "fx__wipe", arguments: %{}}, ctx) == :human
      assert Tools.gate(%{name: "fx__wipe", arguments: %{}}, %{cwd: "/w"}) == :run
    end
  end

  test "refused/2: why a path may not be written, or nil" do
    assert Tools.refused("deps/x/a.ex", "/w") =~ "refused: deps/ holds fetched dependencies"
    assert Tools.refused("/w/.git/config", "/w") =~ "refused: .git/"
    assert Tools.refused("lib/a.ex", "/w") == nil
  end

  test "names_for/1: fetch only where the run's network setting allows it" do
    assert Tools.names_for(%{network: :forbidden}) == ~w(read write edit bash script)
    assert Tools.names_for(%{network: :allowed}) == ~w(read write edit bash script fetch)
    assert Tools.names_for(%{network: ["a.test"], skills: [%{name: "a"}]}) == ~w(read write edit bash script skill fetch)
    assert Tools.names_for(%{network: :allowed, tools: ~w(fetch)}) == ~w(fetch)
    assert Tools.names_for(%{tools: ~w(fetch)}) == []
  end

  test "the fetch tool: a URL becomes a fetch effect answered as a tool result; without a URL, bad arguments" do
    ctx = %{cwd: "/w", network: :allowed}

    assert {:ok, %Effect{kind: :fetch, args: %{url: "https://a.test/x"}, reply: :tool_done}} =
             Tools.to_effect(%{name: "fetch", arguments: %{"url" => "https://a.test/x"}}, ctx)

    assert {:error, "invalid arguments for fetch" <> _} = Tools.to_effect(%{name: "fetch", arguments: %{}}, ctx)

    assert {:error, "unknown tool \"fetch\"" <> _} =
             Tools.to_effect(%{name: "fetch", arguments: %{"url" => "https://a.test"}}, %{cwd: "/w"})

    assert [%{function: %{name: "fetch"}}] = Tools.specs(["fetch"])
  end

  test "names_for/1: the core tools, skill with skills, none when off, only those listed" do
    assert Tools.names_for(%{}) == ~w(read write edit bash script)
    assert Tools.names_for(%{skills: [%{name: "a"}]}) == ~w(read write edit bash script skill)
    assert Tools.names_for(%{tools: false}) == []
    assert Tools.names_for(%{tools: ~w(bash read)}) == ~w(read bash)
    assert Tools.names_for(%{tools: ~w(skill read), skills: [%{name: "a"}]}) == ~w(read skill)
    assert Tools.names_for(%{tools: ~w(skill)}) == []
    assert {:error, "unknown tool \"bash\"; available: read"} = effect("bash", %{"command" => "ls"}, %{tools: ["read"]})
  end
end
