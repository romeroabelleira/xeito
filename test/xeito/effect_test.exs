defmodule Xeito.EffectTest do
  use ExUnit.Case, async: true

  alias Xeito.Effect

  test "chat/2: an ordinary request carries no error" do
    refute Map.has_key?(Effect.chat([%{role: "user", content: "hi"}]).args, :error)
  end

  test "script/2: a program to run in the session's sandbox, with its workspace and time limit" do
    assert %Effect{kind: :script, args: %{code: "1 + 1", cwd: "/w", timeout: 300_000}, reply: :scripted} =
             Effect.script("1 + 1", cwd: "/w")

    assert %Effect{args: %{timeout: 5_000}, reply: :tool_done} = Effect.script("1", timeout: 5_000, reply: :tool_done)
    # The sandbox's fingerprint, so a replay knows whether the script would see the same allow-list.
    assert Effect.script("1").args.sandbox == Xeito.Scripts.Allowlist.fingerprint()
  end

  test "remember/3: an object for the run's log, written by a script" do
    assert %Effect{
             kind: :remember,
             args: %{id: "issue:42", type: "issue", attrs: %{"urgency" => "high"}},
             reply: :remembered
           } =
             Effect.remember("issue:42", "issue", %{"urgency" => "high"})

    assert Effect.replay(Effect.remember("issue:42", "issue", %{})) == :safe
  end

  test "mcp/4: a tool of an MCP server, with what its annotations let the rules decide; only a read-only one may run again" do
    assert %Effect{
             kind: :mcp,
             args: %{server: "fx", tool: "echo", args: %{"text" => "x"}, cwd: "/w", risk: :review},
             reply: :mcp_done
           } =
             Effect.mcp("fx", "echo", %{"text" => "x"}, cwd: "/w")

    assert Effect.replay(Effect.mcp("fx", "echo", %{}, risk: :safe)) == :safe
    assert Effect.replay(Effect.mcp("fx", "wipe", %{}, risk: :review)) == :unsafe
    assert Effect.replay(Effect.mcp("fx", "wipe", %{})) == :unsafe
  end

  test "now/0 and random/0: a reading of the runner's clock or randomness, logged so a replay sees it" do
    assert %Effect{kind: :now, args: %{}, reply: :now} = Effect.now()
    assert %Effect{kind: :random, args: %{}, reply: :random} = Effect.random()
    assert Effect.replay(Effect.now()) == :safe
    assert Effect.replay(Effect.random()) == :safe
  end

  describe "child effects: the calls a script makes" do
    test "a child's id is its parent's with a call number; the parent is read back from it" do
      assert Effect.child_id("ses/t1/e3", 2) == "ses/t1/e3/c2"
      assert Effect.parent("ses/t1/e3/c2") == "ses/t1/e3"
      assert Effect.parent("ses/t1/e3") == nil
      assert Effect.child?(%Effect{id: "ses/t1/e3/c12", kind: :read, args: %{}, reply: :read})
      refute Effect.child?(%Effect{id: "ses/t1/e3", kind: :read, args: %{}, reply: :read})
      refute Effect.child?(%Effect{id: nil, kind: :read, args: %{}, reply: :read})
    end
  end

  describe "replay/1: whether an effect may run again after a crash" do
    test "reading, deciding, asking a model and writing a whole file may" do
      for effect <- [
            Effect.read("a.ex"),
            Effect.write("a.ex", "content"),
            Effect.chat([%{role: "user", content: "hi"}]),
            Effect.decide(Xeito.Decisions.Triage, %{test: "t", output: "o"})
          ],
          do: assert(Effect.replay(effect) == :safe, inspect(effect.kind))
    end

    test "a child machine may: it resumes from its own log rather than starting over" do
      assert Effect.replay(%Effect{kind: :machine, args: %{}, reply: :child_done}) == :safe
    end

    test "an edit may not: its text was replaced once already" do
      assert Effect.replay(Effect.edit("a.ex", "old", "new")) == :unsafe
    end

    test "a script may: run again, it is fed the results its calls got the first time" do
      assert Effect.replay(Effect.script("Script.bash(\"ls\")", cwd: "/w")) == :safe
    end

    test "a command only when it is repeatable: a read, or a write a second run leaves as the first" do
      assert Effect.replay(Effect.bash("mix test")) == :safe
      assert Effect.replay(Effect.bash("mkdir -p out && touch out/x")) == :safe
      assert Effect.replay(Effect.bash("git push")) == :unsafe
      assert Effect.replay(Effect.bash("git branch -D x")) == :unsafe
    end
  end

  @tag :tmp_dir
  test "undoable/1: for a command, whether undo would take it back; nil for a read or another kind",
       %{tmp_dir: dir} do
    assert Effect.undoable(Effect.bash("touch a.txt", cwd: dir)) == true
    assert Effect.undoable(Effect.bash("echo x > ../x", cwd: dir)) == false
    assert Effect.undoable(Effect.bash("ls", cwd: dir)) == nil
    assert Effect.undoable(Effect.read("a.ex")) == nil
  end
end
