defmodule Xeito.Tui.TranscriptTest do
  use ExUnit.Case, async: true

  alias Xeito.Client.StatusBar
  alias Xeito.Tui.Transcript

  defp session_state do
    %{
      usage: StatusBar.new(),
      lines: [],
      partial: "",
      live: [],
      live_partial: "",
      marker: nil,
      decisions: 0,
      tier: nil,
      usd: 0.0,
      leaf: "idle",
      waiting: false
    }
  end

  test "a risk decision marks the line it applies to with a coloured dot and its confidence" do
    decision = %{
      "event" => "decision_made",
      "run" => "ses-x/t1",
      "attrs" => %{
        "decision_type" => "Xeito.Decisions.Risk",
        "value" => "review",
        "actor" => "local",
        "confidence" => 0.94
      }
    }

    state =
      session_state()
      |> Transcript.apply_event(decision)
      |> Transcript.apply_event(%{"event" => "state_entered", "run" => "ses-x/t1", "attrs" => %{"state" => "ask_human"}})
      |> Transcript.apply_event(%{
        "event" => "effect_requested",
        "run" => "ses-x/t1",
        "attrs" => %{"kind" => "bash", "args" => %{"cmd" => "rm -rf _build"}}
      })

    # No line of its own; the state line stays plain; the command carries the marker.
    assert [_state_line, {:marked, :yellow, "⁹⁴", "$ rm -rf _build"}] = state.lines
    refute Enum.any?(state.lines, &(is_binary(&1) and &1 =~ "risk"))
  end

  test "text is added line by line; the unfinished line waits in partial" do
    state = session_state() |> Transcript.append("one\ntw") |> Transcript.append("")
    assert {state.lines, state.partial} == {["one"], "tw"}
    state = Transcript.append(state, "o\n")
    assert {state.lines, state.partial} == {["one", "two"], ""}
  end

  test "a running command's last lines, without colours, the line being written included" do
    output = fn state, text -> Transcript.apply_event(state, %{"event" => "output", "attrs" => %{"text" => text}}) end
    state = session_state() |> output.("1\n2\n3\n4\n5\n\e[1m6\e[0m\n") |> output.("50%\r90%")
    assert Transcript.live_lines(state) == ["3", "4", "5", "6", "90%"]
    assert Transcript.live_lines(session_state()) == []
  end
end
