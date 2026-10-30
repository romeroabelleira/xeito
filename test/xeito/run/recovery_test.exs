defmodule Xeito.Run.RecoveryTest do
  use ExUnit.Case, async: true

  alias Xeito.Machine
  alias Xeito.Machines.Chat
  alias Xeito.Run.Recovery

  defp msg(role, content), do: %{role: role, content: content}

  test "rebuild/2 detects a logged effect that differs from the one it recomputes (desync)" do
    chat = Machine.fetch!(Chat)
    input = %{cwd: "/w", prompt: "hi", messages: [], system: "s"}
    # A chat turn first decides on a skill; the first model request follows.
    started = Machine.Engine.start(chat, input)
    [skill] = started.effects
    {:ok, step} = Machine.Engine.handle(chat, started.leaf, started.ctx, {:decided, :none}, %{value: :none})
    [effect] = step.effects
    {skill, effect} = {%{skill | id: "r/e1"}, %{effect | id: "r/e2"}}

    entries = fn logged ->
      [
        {1, "run_started", {:run_started, Chat, chat.version, input}},
        {2, "effect_requested", {:effect_requested, skill}},
        {3, "effect_completed", {:effect_completed, "r/e1", %{value: :none}}},
        {4, "event_received", {:event, {:decided, :none}, %{value: :none}, :code}},
        {5, "effect_requested", {:effect_requested, logged}}
      ]
    end

    assert {:ok, %{desync: nil, pending: [^effect]}} = Recovery.rebuild(Chat, entries.(effect))

    tampered = put_in(effect.args.messages, [msg("system", "s"), msg("user", "something else")])
    assert {:ok, %{desync: "r/e2"}} = Recovery.rebuild(Chat, entries.(tampered))
  end
end
