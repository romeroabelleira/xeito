defmodule Xeito.EffectTest do
  use ExUnit.Case, async: true

  alias Xeito.Effect

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

    test "a command only when it is repeatable" do
      assert Effect.replay(Effect.bash("mix test")) == :safe
      assert Effect.replay(Effect.bash("git push")) == :unsafe
    end
  end
end
