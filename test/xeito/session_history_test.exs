defmodule Xeito.SessionHistoryTest do
  @moduledoc "The session's history window: trimmed with slack, a summary of earlier turns kept (P4c)."
  use ExUnit.Case, async: true

  alias Xeito.Chat.Window
  alias Xeito.Session

  defp messages(n), do: for(i <- 1..n, do: %{role: if(rem(i, 2) == 1, do: "user", else: "assistant"), content: "m#{i}"})

  test "up to 80 messages stay; past that, the last 60" do
    assert Session.trim_history(messages(80)) == messages(80)
    assert Session.trim_history(messages(81)) == Enum.take(messages(81), -60)
  end

  test "a summary of earlier turns stays first when the window is trimmed" do
    summary = Window.summary_message("Goal: x.", messages(30))
    assert [^summary | rest] = Session.trim_history([summary | messages(85)])
    assert rest == Enum.take(messages(85), -59)
  end
end
