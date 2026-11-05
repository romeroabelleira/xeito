defmodule Xeito.Scripts.ReplayTest do
  # The verify tests start a real second VM: not async.
  use ExUnit.Case, async: false

  alias Xeito.Effect
  alias Xeito.Scripts.Replay
  alias Xeito.Scripts.Sandbox

  @cwd "/w"

  defp script(id \\ "r/e1"), do: %{Effect.script("x", cwd: @cwd) | id: id}

  defp entries do
    c1 = %{Effect.read("a.ex", cwd: @cwd) | id: "r/e1/c1"}
    c2 = %{Effect.bash("ls", cwd: @cwd, timeout: 50) | id: "r/e1/c2"}
    other = %{Effect.read("b.ex", cwd: @cwd) | id: "r/e3/c1"}

    [
      {0, "run_started", {:run_started, Xeito.TestMachines.Scripted, "1.0.0", %{cwd: @cwd}}},
      {1, "effect_requested", {:effect_requested, script()}},
      {2, "effect_requested", {:effect_requested, c1}},
      {3, "effect_completed", {:effect_completed, "r/e1/c1", %{ok: true, content: "A"}}},
      {4, "effect_requested", {:effect_requested, c2}},
      {5, "effect_requested", {:effect_requested, other}},
      {6, "effect_completed", {:effect_completed, "r/e3/c1", %{ok: true, content: "B"}}}
    ]
  end

  test "logged/2: a script's finished calls with their results, in order, and the one it began last" do
    assert %{replay: [{%Effect{id: "r/e1/c1"}, %{content: "A"}}], incomplete: %Effect{id: "r/e1/c2"}} =
             Replay.logged(entries(), "r/e1")

    assert %{replay: [{%Effect{id: "r/e3/c1"}, _}], incomplete: nil} = Replay.logged(entries(), "r/e3")
    assert %{replay: [], incomplete: nil} = Replay.logged(entries(), "r/e9")
  end

  test "logged/2: a call begun and abandoned earlier is dropped when it ran again, else kept as interrupted" do
    again = %{Effect.read("a.ex", cwd: @cwd) | id: "r/e1/c1"}
    once = %{Effect.bash("echo hi > out.txt", cwd: @cwd) | id: "r/e1/c2"}
    last = %{Effect.now() | id: "r/e1/c3"}

    entries = [
      {1, "effect_requested", {:effect_requested, again}},
      {2, "effect_requested", {:effect_requested, once}},
      {3, "effect_requested", {:effect_requested, last}},
      {4, "effect_completed", {:effect_completed, "r/e1/c3", %{value: 1}}}
    ]

    assert %{replay: [{^once, :interrupted}, {^last, %{value: 1}}], incomplete: nil} = Replay.logged(entries, "r/e1")
  end

  describe "feed/2: the next call of a script run again" do
    defp state(replay, incomplete \\ nil), do: %{replay: replay, incomplete: incomplete}

    test "the logged result when the call is the same, a desync when not, interrupted when it was" do
      c1 = %{Effect.read("a.ex", cwd: @cwd) | id: "r/e1/c1"}
      c2 = %{Effect.now() | id: "r/e1/c2"}
      state = state([{c1, %{ok: true, content: "A"}}, {c2, :interrupted}])

      assert {:logged, %{content: "A"}, state} = Replay.feed(state, Effect.read("a.ex", cwd: @cwd))
      assert {:desync, ^c2} = Replay.feed(state, Effect.random())
      assert {:interrupted, "r/e1/c2", state} = Replay.feed(state, Effect.now())
      assert {:live, ^state} = Replay.feed(state, Effect.random())
    end

    test "the call the run stopped in runs again when it may, else the script is told; another call is a desync" do
      read = %{Effect.read("a.ex", cwd: @cwd) | id: "r/e1/c1"}
      assert {:live, %{incomplete: nil}} = Replay.feed(state([], read), Effect.read("a.ex", cwd: @cwd))
      assert {:desync, ^read} = Replay.feed(state([], read), Effect.now())

      write = %{Effect.bash("echo hi > out.txt", cwd: @cwd) | id: "r/e1/c1"}

      assert {:interrupted, "r/e1/c1", %{incomplete: nil}} =
               Replay.feed(state([], write), Effect.bash("echo hi > out.txt", cwd: @cwd))
    end
  end

  describe "verify/2: each finished script run again in a sandbox" do
    @moduletag :sandbox

    setup do
      Process.flag(:trap_exit, true)
      {:ok, sandbox} = Sandbox.start()
      on_exit(fn -> Sandbox.stop(sandbox) end)
      %{sandbox: sandbox}
    end

    # A run whose script read a.ex, got `content`, and ended with `result`; `code` is what runs again.
    defp run(code, content, result, id \\ "r/e1") do
      script = %{Effect.script(code, cwd: @cwd, timeout: 10_000) | id: id}
      c1 = %{Effect.read("a.ex", cwd: @cwd) | id: id <> "/c1"}

      [
        {1, "effect_requested", {:effect_requested, script}},
        {2, "effect_requested", {:effect_requested, c1}},
        {3, "effect_completed", {:effect_completed, id <> "/c1", %{ok: true, content: content, ref: id <> "/c1"}}},
        {4, "effect_completed", {:effect_completed, id, result}}
      ]
    end

    @code ~s|{:ok, text} = Script.read("a.ex"); String.upcase(text)|

    test "the same calls and the same result replay exactly; a different result is a desync at the script",
         %{sandbox: sandbox} do
      assert {:ok, sandbox} = Replay.verify(run(@code, "abc", %{ok: true, content: "ABC", ref: "r/e1"}), sandbox)
      assert {{:desync, "r/e1"}, sandbox} = Replay.verify(run(@code, "abc", %{ok: true, content: "abc"}), sandbox)

      # A failure that replays as the same failure is exact; a different message is not.
      failing = ~s|Script.read("a.ex"); raise "boom"|

      assert {:ok, sandbox} =
               Replay.verify(run(failing, "abc", %{ok: false, error: "exception: ** (RuntimeError) boom"}), sandbox)

      assert {{:desync, "r/e1"}, _} = Replay.verify(run(failing, "abc", %{ok: false, error: "exception: other"}), sandbox)
    end

    test "a different call, or one past the end of the log, is a desync naming the call", %{sandbox: sandbox} do
      other = ~s|{:ok, text} = Script.read("b.ex"); String.upcase(text)|
      assert {{:desync, "r/e1/c1"}, sandbox} = Replay.verify(run(other, "abc", %{ok: true, content: "ABC"}), sandbox)

      more = ~s|{:ok, a} = Script.read("a.ex"); {:ok, b} = Script.read("a.ex"); a <> b|
      assert {{:desync, "r/e1/c2"}, _} = Replay.verify(run(more, "abc", %{ok: true, content: "abcabc"}), sandbox)
    end

    test "a script from another sandbox is an error; the first script that fails ends the run's check",
         %{sandbox: sandbox} do
      [{1, type, {:effect_requested, script}} | rest] = run(@code, "abc", %{ok: true, content: "ABC"})
      stale = [{1, type, {:effect_requested, put_in(script.args.sandbox, "0000")}} | rest]
      assert {{:error, "the sandbox changed" <> _}, sandbox} = Replay.verify(stale, sandbox)

      second = run(@code, "abc", %{ok: true, content: "abc"}, "r/e2")
      assert {{:desync, "r/e2"}, _} = Replay.verify(run(@code, "abc", %{ok: true, content: "ABC"}) ++ second, sandbox)
    end
  end

  test "same?/2: the call the script makes against the logged one: kind and arguments, not a command's time limit" do
    assert Replay.same?(Effect.bash("ls", cwd: @cwd, timeout: 1), %{Effect.bash("ls", cwd: @cwd, timeout: 99) | id: "c"})
    refute Replay.same?(Effect.bash("ls -a", cwd: @cwd), Effect.bash("ls", cwd: @cwd))
    refute Replay.same?(Effect.read("ls", cwd: @cwd), Effect.bash("ls", cwd: @cwd))
    assert Replay.same?(Effect.now(), Effect.now())
    refute Replay.same?(Effect.now(), Effect.random())
  end

  test "describe/1: a call in a few words, for a desync message" do
    assert Replay.describe(Effect.read("a.ex", cwd: @cwd)) == ~s(read "a.ex")
    assert Replay.describe(Effect.bash("ls -a", cwd: @cwd)) == ~s(bash "ls -a")
    assert Replay.describe(Effect.now()) == "now"
    assert Replay.describe(Effect.write("a.ex", "x", cwd: @cwd)) == ~s(write "a.ex")
    assert Replay.describe(Effect.edit("a.ex", "x", "y", cwd: @cwd)) == ~s(edit "a.ex")
    assert Replay.describe(Effect.decide(Xeito.Decisions.Triage, %{})) == "decide Xeito.Decisions.Triage"
    assert Replay.describe(Effect.remember("issue:42", "issue", %{})) == ~s(remember "issue:42")
    assert Replay.describe(Effect.mcp("fx", "echo", %{})) == "mcp fx.echo"
  end

  test "scripts/1: the finished scripts of a run, each with its logged result" do
    entries = entries() ++ [{7, "effect_completed", {:effect_completed, "r/e1", %{ok: true, content: "done"}}}]
    assert [{%Effect{id: "r/e1", kind: :script}, %{content: "done"}}] = Replay.scripts(entries)
    assert Replay.scripts(entries()) == []
  end
end
