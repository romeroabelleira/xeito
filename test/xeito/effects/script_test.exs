defmodule Xeito.Effects.ScriptTest do
  use ExUnit.Case, async: true

  alias Xeito.Decision.Type
  alias Xeito.Decisions.Triage
  alias Xeito.Effect
  alias Xeito.Effects.Local
  alias Xeito.Effects.Script
  alias Xeito.Log.Event
  alias Xeito.Scripts.Host

  @moduletag :tmp_dir

  # The accumulator of a script whose children are run directly by `child`, and recorded.
  defp acc(ws, child \\ nil) do
    test = self()

    child =
      child ||
        fn parent, effect ->
          send(test, {:child, parent, effect})
          Local.run(effect, [])
        end

    Script.start(%{Effect.script("1", cwd: ws, timeout: 10_000) | id: "r/e1"},
      child: child,
      run_id: "r",
      tools: [],
      network: :forbidden
    )
  end

  defp mcp_tool(name, annotations, exposure \\ :script),
    do: %{
      server: "fx",
      name: name,
      description: "does #{name}",
      schema: %{},
      annotations: annotations,
      exposure: exposure
    }

  describe "handle/3: one call from the script" do
    test "read and bash become child effects of the script's, and the script sees their results as JSON would",
         %{tmp_dir: ws} do
      File.write!(Path.join(ws, "a.ex"), "defmodule A do\nend\n")

      assert {%{"ok" => true, "content" => "defmodule A do\nend\n"} = value, acc} =
               Script.handle("read", ["a.ex"], acc(ws))

      refute Map.has_key?(value, "ref")
      assert_received {:child, "r/e1", %Effect{kind: :read, args: %{path: "a.ex", cwd: ^ws}}}

      assert {%{"exit_status" => 0, "output" => "a.ex\n"}, _acc} = Script.handle("bash", ["ls"], acc)
      assert_received {:child, "r/e1", %Effect{kind: :bash, args: %{cmd: "ls", cwd: ^ws, timeout: timeout}}}
      assert timeout in 9_000..10_000
    end

    test "the script sees a child's whole result, not the model's shaping or the reference", %{tmp_dir: ws} do
      File.mkdir_p!(Path.join(ws, "deps/x"))
      File.write!(Path.join(ws, "deps/x/big.txt"), Enum.map_join(1..500, "\n", &"line #{&1}"))
      # As the run numbers it: with an id, so the runner shapes and references the result.
      child = fn parent, effect -> Local.run(%{effect | id: parent <> "/c1"}, []) end

      assert {%{"ok" => true, "content" => content} = value, _acc} =
               Script.handle("read", ["deps/x/big.txt"], acc(ws, child))

      assert length(String.split(content, "\n")) == 500
      assert Map.keys(value) == ["content", "ok"]
    end

    test "a command's time limit is what is left of the script's, at least a second", %{tmp_dir: ws} do
      acc = %{acc(ws) | deadline: System.monotonic_time(:millisecond) - 5_000}
      assert {%{"exit_status" => 0}, _acc} = Script.handle("bash", ["ls"], acc)
      assert_received {:child, _, %Effect{kind: :bash, args: %{timeout: 1_000}}}
    end

    test "a command the rules would send to review fails the call, saying so, and the script goes on",
         %{tmp_dir: ws} do
      assert {%{"ok" => false, "error" => error}, acc} = Script.handle("bash", ["npm install"], acc(ws))
      assert error =~ "not run: `npm install` would need a review"
      assert error =~ "bash tool"
      refute_received {:child, _, _}
      assert acc.stopped == nil
    end

    test "a forbidden command stops the script: that call and every later one fail", %{tmp_dir: ws} do
      assert {%{"ok" => false, "error" => "stopped: " <> reason}, acc} = Script.handle("bash", ["rm -rf ~/"], acc(ws))
      assert reason =~ "`rm -rf ~/` is forbidden"
      assert acc.stopped == reason
      assert {%{"ok" => false, "error" => "stopped: " <> ^reason}, ^acc} = Script.handle("read", ["a.ex"], acc)
      assert {%{"ok" => false, "error" => "stopped: " <> ^reason}, ^acc} = Script.handle("now", [], acc)
      refute_received {:child, _, _}
    end

    test "text adds to the output, as text; now and random are child effects too; anything else is an error",
         %{tmp_dir: ws} do
      assert {"hi", acc} = Script.handle("text", ["hi"], acc(ws))
      assert {~s(%{"n" => 1}), acc} = Script.handle("text", [%{"n" => 1}], acc)
      assert acc.texts == [~s(%{"n" => 1}), "hi"]

      assert {now, _} = Script.handle("now", [], acc)
      assert is_integer(now) and now > 1_700_000_000_000
      assert_received {:child, "r/e1", %Effect{kind: :now}}

      assert {random, _} = Script.handle("random", [], acc)
      assert is_float(random) and random >= 0 and random < 1
      assert_received {:child, "r/e1", %Effect{kind: :random}}

      assert {%{"ok" => false, "error" => "unknown call nope/2"}, ^acc} = Script.handle("nope", [1, 2], acc)
      assert {%{"ok" => false, "error" => "read takes a path"}, ^acc} = Script.handle("read", [1], acc)
      assert {%{"ok" => false, "error" => "bash takes a command"}, ^acc} = Script.handle("bash", [], acc)
    end
  end

  describe "handle/3: writes, decisions and objects" do
    test "write and edit become child effects; a protected directory is refused as for the tools", %{tmp_dir: ws} do
      assert {%{"ok" => true}, acc} = Script.handle("write", ["a.txt", "one\n"], acc(ws))
      assert_received {:child, "r/e1", %Effect{kind: :write, args: %{path: "a.txt", content: "one\n", cwd: ^ws}}}
      assert File.read!(Path.join(ws, "a.txt")) == "one\n"

      assert {%{"ok" => true}, acc} = Script.handle("edit", ["a.txt", "one", "two"], acc)
      assert_received {:child, "r/e1", %Effect{kind: :edit, args: %{path: "a.txt", old: "one", new: "two"}}}
      assert File.read!(Path.join(ws, "a.txt")) == "two\n"

      assert {%{"ok" => false, "error" => "old_text not found" <> _}, acc} =
               Script.handle("edit", ["a.txt", "zzz", "y"], acc)

      assert {%{"ok" => false, "error" => "refused: deps/ " <> _}, acc} = Script.handle("write", ["deps/x.ex", "x"], acc)

      assert {%{"ok" => false, "error" => "refused: .git/ " <> _}, acc} =
               Script.handle("edit", [".git/HEAD", "a", "b"], acc)

      refute_received {:child, _, %Effect{kind: :write}}

      for args <- [["a"], ["a", 1], [1, "x"]] do
        assert {%{"ok" => false, "error" => "write takes a path and the content"}, ^acc} =
                 Script.handle("write", args, acc)
      end

      for args <- [[1], [1, "a", "b"], ["a", 1, "b"], ["a", "b", 1]] do
        assert {%{"ok" => false, "error" => "edit takes a path, the old text and the new"}, ^acc} =
                 Script.handle("edit", args, acc)
      end
    end

    test "decide runs a registered type by name, as a child decide effect, and gives the script the verdict",
         %{tmp_dir: ws} do
      child = fn "r/e1", %Effect{kind: :decide, args: %{decision: Triage, input: input}} ->
        send(self(), {:decided, input})
        decision = %Xeito.Decision{type: Triage, value: :flaky, confidence: 0.9, actor: :local_decision, model: "m"}
        %{value: :flaky, decision: Xeito.Decision.to_map(%{decision | probabilities: %{flaky: 0.9, code_bug: 0.1}})}
      end

      input = %{"test" => "t", "output" => "timeout"}

      assert {%{
                "value" => "flaky",
                "confidence" => 0.9,
                "actor" => "local_decision",
                "model" => "m",
                "probabilities" => probabilities
              }, _acc} = Script.handle("decide", ["triage", input], acc(ws, child))

      assert probabilities == %{"flaky" => 0.9, "code_bug" => 0.1}
      assert_received {:decided, ^input}

      assert {%{"ok" => false, "error" => "unknown decision type \"nope\"; the types are " <> names}, _} =
               Script.handle("decide", ["nope", %{}], acc(ws))

      assert names =~ "triage"

      for args <- [[1], [1, %{}], ["triage", "x"]] do
        assert {%{"ok" => false, "error" => "decide takes a type name and an input map"}, _} =
                 Script.handle("decide", args, acc(ws))
      end

      # A decision that could not be made comes back as the runner reported it.
      undecided = fn _, %Effect{kind: :decide} -> %{value: :abstain, error: "no tier could decide"} end

      assert {%{"value" => "abstain", "error" => "no tier could decide"}, _} =
               Script.handle("decide", ["triage", %{}], acc(ws, undecided))
    end

    test "classify runs one ad-hoc decision per question, on the decision tiers, and answers by name",
         %{tmp_dir: ws} do
      child = fn "r/e1", %Effect{kind: :decide, args: %{decision: %Type{name: name} = type, input: input}} ->
        send(self(), {:asked, name, type, input})
        [value | _] = Type.values(type)
        decision = %Xeito.Decision{type: type, value: value, confidence: 0.7, actor: :local, model: "m"}
        %{value: value, decision: Xeito.Decision.to_map(decision)}
      end

      questions = %{
        "urgency" => %{"type" => "choice", "options" => ["low", "high"], "criteria" => "How urgent?"},
        "fixable" => %{"type" => "bool", "criteria" => "Can it be fixed now?"}
      }

      assert {%{"fixable" => %{"value" => "yes", "confidence" => 0.7}, "urgency" => %{"value" => "low"}}, _acc} =
               Script.handle("classify", [questions, %{"todo" => "fix later"}], acc(ws, child))

      assert_received {:asked, "classify:fixable", %{deciders: [:local_decision, :local]},
                       %{"state" => ~s({"todo":"fix later"})}}

      assert_received {:asked, "classify:urgency", _, _}

      bad = %{"urgency" => %{"type" => "rank"}}

      assert {%{"ok" => false, "error" => "urgency: unknown question type" <> _}, _} =
               Script.handle("classify", [bad, %{}], acc(ws))

      for args <- [[[], 1], [%{}, 1], [[], %{}]] do
        assert {%{"ok" => false, "error" => "classify takes a map of questions and a state map"}, _} =
                 Script.handle("classify", args, acc(ws))
      end

      # The question itself where the named questions go: what a model does with the description's shape.
      one = %{"name" => "urgency", "type" => "choice", "options" => ["low", "high"], "criteria" => "How urgent?"}

      assert {%{"ok" => false, "error" => "classify takes named questions, " <> rest}, _} =
               Script.handle("classify", [one, %{}], acc(ws))

      assert rest =~ ~s|%{"urgency" => %{"type" => "choice", ...}}|
      assert rest =~ "this is one question without a name"

      refute_received {:asked, _, _, _}
    end

    test "remember writes an object to the log through a child effect", %{tmp_dir: ws} do
      child = fn "r/e1", %Effect{kind: :remember} = effect ->
        send(self(), {:remembered, effect})
        %{ok: true}
      end

      assert {%{"ok" => true}, _} =
               Script.handle("remember", ["issue:42", %{"type" => "issue", "urgency" => "high"}], acc(ws, child))

      assert_received {:remembered, %Effect{args: %{id: "issue:42", type: "issue", attrs: %{"urgency" => "high"}}}}

      assert {%{"ok" => true}, _} = Script.handle("remember", ["note:1", %{"text" => "x"}], acc(ws, child))
      assert_received {:remembered, %Effect{args: %{id: "note:1", type: "object", attrs: %{"text" => "x"}}}}

      for args <- [[1, 2], [1, %{}], ["id", 2]] do
        assert {%{"ok" => false, "error" => "remember takes an id and a map of attributes"}, _} =
                 Script.handle("remember", args, acc(ws))
      end
    end
  end

  describe "handle/3: MCP tools" do
    @echo %{"readOnlyHint" => true, "openWorldHint" => false}
    @lookup %{"readOnlyHint" => true, "openWorldHint" => true}
    @wipe %{"destructiveHint" => true, "openWorldHint" => false}

    test "a read-only, closed-world tool runs as a child mcp effect, safe by rule", %{tmp_dir: ws} do
      child = fn "r/e1", %Effect{kind: :mcp} = effect ->
        send(self(), {:called, effect})
        %{ok: true, content: "hi", ref: "r/e1/c1"}
      end

      acc = %{acc(ws, child) | tools: [mcp_tool("echo", @echo)]}
      assert {%{"ok" => true, "content" => "hi"}, _} = Script.handle("mcp", ["fx", "echo", %{"text" => "hi"}], acc)

      assert_received {:called,
                       %Effect{args: %{server: "fx", tool: "echo", args: %{"text" => "hi"}, cwd: ^ws, risk: :safe}}}
    end

    test "a tool that would need a review, an open-world one under a forbidding policy, or an unknown one fails the call",
         %{tmp_dir: ws} do
      acc = %{acc(ws) | tools: [mcp_tool("wipe", @wipe), mcp_tool("lookup", @lookup)]}

      assert {%{"ok" => false, "error" => "not run: fx.wipe would need a review" <> _}, _} =
               Script.handle("mcp", ["fx", "wipe", %{}], acc)

      assert {%{"ok" => false, "error" => "refused: fx__lookup reaches outside" <> _}, _} =
               Script.handle("mcp", ["fx", "lookup", %{}], acc)

      # With the network allowed, an open-world read-only tool is still not safe by rule: it goes to review.
      assert {%{"ok" => false, "error" => "not run: fx.lookup would need a review" <> _}, _} =
               Script.handle("mcp", ["fx", "lookup", %{}], %{acc | network: :allowed})

      assert {%{"ok" => false, "error" => "no MCP tool fx.nope; find tools" <> _}, _} =
               Script.handle("mcp", ["fx", "nope", %{}], acc)

      for args <- [["fx"], [1, "t", %{}], ["fx", 1, %{}], ["fx", "t", 1]] do
        assert {%{"ok" => false, "error" => "mcp takes a server name, a tool name and an arguments map"}, _} =
                 Script.handle("mcp", args, acc)
      end

      refute_received {:child, _, _}
    end

    test "search_tools finds tools by words, as the script can use them", %{tmp_dir: ws} do
      acc = %{acc(ws) | tools: [mcp_tool("echo", @echo), mcp_tool("lookup", @lookup)]}

      assert {[%{"server" => "fx", "name" => "lookup", "description" => "does lookup", "schema" => %{}}], _} =
               Script.handle("search_tools", ["lookup"], acc)

      assert {[], _} = Script.handle("search_tools", ["nothing"], acc)
      assert {%{"ok" => false, "error" => "search_tools takes a query"}, _} = Script.handle("search_tools", [1], acc)
    end
  end

  describe "replay: a script run again is fed what its calls got the first time" do
    defp logged(ws) do
      [
        {%{Effect.read("a.ex", cwd: ws) | id: "r/e1/c1"}, %{ok: true, content: "as logged", ref: "r/e1/c1"}},
        {%{Effect.bash("ls", cwd: ws, timeout: 123) | id: "r/e1/c2"}, %{exit_status: 0, output: "logged\n"}},
        {%{Effect.now() | id: "r/e1/c3"}, %{value: 1_700_000_000_000}}
      ]
    end

    test "each call gets the logged result of the call at the same place, and no effect runs", %{tmp_dir: ws} do
      acc = %{acc(ws) | replay: logged(ws)}
      assert {%{"ok" => true, "content" => "as logged"}, acc} = Script.handle("read", ["a.ex"], acc)
      # The command's time limit is what was left of the script's then: not part of the comparison.
      assert {%{"exit_status" => 0, "output" => "logged\n"}, acc} = Script.handle("bash", ["ls"], acc)
      assert {1_700_000_000_000, acc} = Script.handle("now", [], acc)
      assert acc.replay == []
      refute_received {:child, _, _}

      # Past the log, the script runs live again.
      assert {random, _} = Script.handle("random", [], acc)
      assert is_float(random)
      assert_received {:child, "r/e1", %Effect{kind: :random}}
    end

    test "a call that differs from the logged one at the same place is a desync naming that call", %{tmp_dir: ws} do
      acc = %{acc(ws) | replay: logged(ws)}
      assert {%{"ok" => false, "error" => "stopped: " <> reason}, acc} = Script.handle("read", ["other.ex"], acc)
      assert reason == ~s(desync at r/e1/c1: the log has read "a.ex", the script asked for read "other.ex")
      assert acc.stopped == reason
      refute_received {:child, _, _}
    end

    test "a call the log began but never finished runs again only if it may; else the script is told", %{tmp_dir: ws} do
      # A write undo covers is safe by rule, but a second run would append or overwrite again.
      acc = %{acc(ws) | replay: [], incomplete: %{Effect.bash("echo hi > out.txt", cwd: ws) | id: "r/e1/c1"}}
      assert {%{"ok" => false, "error" => "interrupted: " <> _}, acc} = Script.handle("bash", ["echo hi > out.txt"], acc)
      assert acc.incomplete == nil
      refute_received {:child, _, _}

      acc = %{acc(ws) | replay: [], incomplete: %{Effect.read("a.ex", cwd: ws) | id: "r/e1/c1"}}
      File.write!(Path.join(ws, "a.ex"), "again")
      assert {%{"ok" => true, "content" => "again"}, %{incomplete: nil}} = Script.handle("read", ["a.ex"], acc)
      assert_received {:child, "r/e1", %Effect{kind: :read}}

      # A different call than the interrupted one is a desync, as a logged one would be.
      acc = %{acc(ws) | replay: [], incomplete: %{Effect.read("a.ex", cwd: ws) | id: "r/e1/c1"}}
      assert {%{"ok" => false, "error" => "stopped: desync at r/e1/c1: " <> _}, _} = Script.handle("now", [], acc)
    end

    test "start/2 takes the logged calls of a recovered script from the run's log", %{tmp_dir: ws} do
      log = Xeito.Case.start_log!()
      effect = %{Effect.script("1", cwd: ws, timeout: 10_000) | id: "r/e1"}
      [{c1, r1}, {c2, _}, _] = logged(ws)

      events = [
        Event.new("effect_requested", {:effect_requested, effect}),
        Event.new("effect_requested", {:effect_requested, c1}),
        Event.new("effect_completed", {:effect_completed, c1.id, r1}),
        Event.new("effect_requested", {:effect_requested, c2})
      ]

      {:ok, _} = Xeito.Log.append(log, "r", events)

      assert %{replay: [{^c1, ^r1}], incomplete: ^c2} = Script.start(effect, log: log, run_id: "r", recovered: true)
      assert %{replay: [], incomplete: nil} = Script.start(effect, log: log, run_id: "r")
      # Given outright (`mix xeito.log verify`), the log is not read.
      assert %{replay: [{^c1, ^r1}], incomplete: ^c2} = Script.start(effect, replay: [{c1, r1}], incomplete: c2)
    end

    test "whoever runs the children may answer a desync, which stops the script the same way", %{tmp_dir: ws} do
      child = fn "r/e1", _asked -> {:desync, "r/e1/c9", "the log ends"} end
      acc = acc(ws, child)

      assert {%{"ok" => false, "error" => "stopped: desync at r/e1/c9: the log ends"}, acc} =
               Script.handle("now", [], acc)

      assert %{desync: "r/e1/c9", stopped: "desync at r/e1/c9: the log ends"} = acc
    end

    test "a script logged under another sandbox is not replayed", %{tmp_dir: ws} do
      effect = %{Effect.script("1", cwd: ws, timeout: 10_000) | id: "r/e1"}
      effect = put_in(effect.args.sandbox, "0000")
      acc = Script.start(effect, child: fn _, _ -> flunk("ran") end, replay: logged(ws))
      assert acc.stopped =~ "the sandbox changed since this script ran"
      assert {%{"ok" => false, "error" => "stopped: the sandbox changed" <> _}, _} = Script.handle("now", [], acc)
    end
  end

  describe "finish/3: the script's outcome as the tool result" do
    test "what the script printed, its texts and its last value, in that order; nil adds nothing",
         %{tmp_dir: ws} do
      acc = %{acc(ws) | texts: ["second", "first"]}
      effect = acc.effect

      assert %{ok: true, content: "printed\nfirst\nsecond\n[1, 2]", ref: "r/e1"} =
               Script.finish(effect, {:ok, [1, 2], "printed\n"}, acc)

      assert %{ok: true, content: "first\nsecond"} = Script.finish(effect, {:ok, nil, ""}, acc)
      assert %{ok: true, content: "a string as is"} = Script.finish(effect, {:ok, "a string as is", ""}, acc(ws))
      assert %{ok: true, content: ~s(%{"a" => 1})} = Script.finish(effect, {:ok, %{"a" => 1}, ""}, acc(ws))
    end

    test "a long output is shaped for the model", %{tmp_dir: ws} do
      long = Enum.map_join(1..300, "\n", &"line #{&1}")
      assert %{ok: true, shaped: shaped} = Script.finish(acc(ws).effect, {:ok, long, ""}, acc(ws))
      assert shaped =~ ~s(full output: read with result: "r/e1")
    end

    test "a failure names its kind and keeps the output so far; a stopped script fails with the reason",
         %{tmp_dir: ws} do
      failure = %{type: :restricted, message: "File.read!/1 is restricted", stdio: ""}
      effect = acc(ws).effect

      assert %{ok: false, error: "restricted: File.read!/1 is restricted"} =
               Script.finish(effect, {:error, failure}, acc(ws))

      assert %{ok: false, error: "exception: boom\n\noutput so far:\nnote"} =
               Script.finish(effect, {:error, %{failure | type: :exception, message: "boom"}}, %{
                 acc(ws)
                 | texts: ["note"]
               })

      jason = "** (UndefinedFunctionError) function Jason.decode!/1 is undefined (module Jason is not available)"

      assert %{ok: false, error: error} =
               Script.finish(effect, {:error, %{failure | type: :exception, message: jason}}, acc(ws))

      assert error =~ "exception: ** (UndefinedFunctionError) function Jason.decode!/1"
      assert error =~ "there is no Jason here: JSON is built in, JSON.decode!/1 and JSON.encode!/1"

      stopped = %{acc(ws) | stopped: "`rm -rf ~/` is forbidden"}
      assert %{ok: false, error: "stopped: `rm -rf ~/` is forbidden"} = Script.finish(effect, {:ok, 1, ""}, stopped)
    end
  end

  @tag :sandbox
  test "run/2: the whole way, in the session's sandbox", %{tmp_dir: ws} do
    File.write!(Path.join(ws, "a.txt"), "one\ntwo\n")
    run = "script-run-#{System.unique_integer([:positive])}"
    on_exit(fn -> Host.stop(run) end)
    child = fn _parent, effect -> Local.run(effect, []) end

    code = ~s|{:ok, text} = Script.read("a.txt"); text \|> String.split("\\n", trim: true) \|> length()|
    effect = %{Effect.script(code, cwd: ws, timeout: 10_000) | id: run <> "/e1"}
    assert %{ok: true, content: "2", ref: ref} = Local.run(effect, run_id: run, child: child)
    assert ref == run <> "/e1"

    effect = %{Effect.script(~s|File.read!("a.txt")|, cwd: ws, timeout: 10_000) | id: run <> "/e2"}
    assert %{ok: false, error: "restricted: " <> _} = Local.run(effect, run_id: run, child: child)

    # Outside a run (no run id), as in a test: a sandbox of its own.
    on_exit(fn -> Host.stop("") end)
    assert %{ok: true, content: "3"} = Local.run(Effect.script("1 + 2", cwd: ws, timeout: 10_000), child: child)
  end
end
