defmodule Xeito.TuiTest do
  use ExUnit.Case, async: true

  alias TermUI.Widgets.TextInput
  alias Xeito.Client.StatusBar
  alias Xeito.Tui

  defp state do
    {:ok, input} = TextInput.init(TextInput.new(width: 20))
    %{input: TextInput.set_focused(input, true), cursor_on: true, blink: 0, blink_until: 0}
  end

  defp cursor_drawn?(state), do: state |> Tui.input_line(20) |> inspect() =~ "bg: :yellow"

  defp typed(state, text) do
    Enum.reduce(String.graphemes(text), state, fn c, st ->
      {:ok, input} = TextInput.handle_event(%TermUI.Event.Key{key: c, char: c}, st.input)
      %{st | input: input}
    end)
  end

  test "the cursor blinks after a key, and stops blinking (solid) once idle" do
    state = Tui.wake_cursor(state())
    gen = state.blink
    assert cursor_drawn?(state)

    assert_receive {:blink, ^gen}, 1_000
    {off, []} = Tui.handle_info({:blink, gen}, state)
    refute off.cursor_on
    refute cursor_drawn?(off)
    # The off phase hides only the drawn cursor, never the stored one.
    assert off.input == state.input

    assert_receive {:blink, ^gen}, 1_000
    {on, []} = Tui.handle_info({:blink, gen}, off)
    assert on.cursor_on
    assert_receive {:blink, ^gen}, 1_000

    # Past the blinking period the cursor stays solid and no timer is scheduled.
    # (Monotonic time can be negative, so "past" is relative to now.)
    past = System.monotonic_time(:millisecond) - 1
    {idle, []} = Tui.handle_info({:blink, gen}, %{off | blink_until: past})
    assert idle.cursor_on
    refute_receive {:blink, _}, 700
  end

  test "the input line draws a block cursor at the typing position and scrolls to keep it visible" do
    st = typed(state(), "hello")
    line = inspect(Tui.input_line(st, 20))
    # The block sits after the text, on a space; an empty line shows the dimmed placeholder.
    assert line =~ ~s(content: "hello") and line =~ "bg: :yellow"
    assert inspect(Tui.input_line(state(), 20)) =~ "ask, or /help"

    long = typed(state(), String.duplicate("x", 30) <> "END")
    shown = long |> Tui.input_line(20) |> inspect()
    assert shown =~ "END" and not (shown =~ String.duplicate("x", 20))
  end

  defp session_state do
    Map.merge(state(), %{
      usage: StatusBar.new(),
      lines: [],
      partial: "",
      marker: nil,
      decisions: 0,
      tier: nil,
      usd: 0.0,
      leaf: "idle",
      waiting: false
    })
  end

  test "a risk decision marks the line it applies to with a coloured dot and its confidence" do
    decision = %{
      "event" => "decision_made",
      "run" => "ses-x/t1",
      "attrs" => %{
        "decision_type" => "Xeito.Decisions.Risk",
        "value" => "review",
        "actor" => "large",
        "confidence" => 0.94
      }
    }

    state =
      session_state()
      |> Tui.apply_event(decision)
      |> Tui.apply_event(%{"event" => "state_entered", "run" => "ses-x/t1", "attrs" => %{"state" => "ask_human"}})
      |> Tui.apply_event(%{
        "event" => "effect_requested",
        "run" => "ses-x/t1",
        "attrs" => %{"kind" => "bash", "args" => %{"cmd" => "rm -rf _build"}}
      })

    # No line of its own; the state line stays plain; the command carries the marker.
    assert [_state_line, {:marked, :yellow, "⁹⁴", "$ rm -rf _build"}] = state.lines
    refute Enum.any?(state.lines, &(is_binary(&1) and &1 =~ "risk"))
  end

  test "the status bar is one line, filled by priority up to the width" do
    usage = StatusBar.new()
    line = StatusBar.line(usage, nil, nil, [], 40)
    assert String.length(line) <= 40 and line =~ "tok"
    refute line =~ "\n"
    assert String.length(StatusBar.line(usage, nil, nil, [], 200)) > 40
    assert StatusBar.line(usage, nil, nil, StatusBar.segments(), 80) == ""
  end

  test "in the blink's off phase the cursor cell is drawn plain" do
    st = typed(state(), "ab")
    assert cursor_drawn?(st)
    refute cursor_drawn?(%{st | cursor_on: false})
    assert inspect(Tui.input_line(%{st | cursor_on: false}, 20)) =~ ~s(content: "ab")
  end

  test "a marked line renders a coloured dot, a dim superscript and the text" do
    node = inspect(Tui.line_node({:marked, :red, "¹⁰⁰", "$ rm -rf /"}))
    assert node =~ ~s(content: "●") and node =~ "fg: :red"
    assert node =~ ~s(content: "¹⁰⁰") and node =~ ":dim"
    assert node =~ ~s(content: " $ rm -rf /")
  end

  test "the status bar keeps the higher-priority segment when two do not fit" do
    usage = StatusBar.new()
    only = StatusBar.segments() -- ~w(calls tokens)
    both = StatusBar.line(usage, nil, nil, only, 200)
    assert both =~ "no model calls yet" and both =~ "tok"

    # Exactly wide enough: both; one less: the higher-priority tokens segment alone.
    assert StatusBar.line(usage, nil, nil, only, String.length(both)) == both
    narrow = StatusBar.line(usage, nil, nil, only, String.length(both) - 1)
    assert narrow =~ "tok" and not (narrow =~ "calls")
  end

  test "a newer key makes older blink timers stale" do
    state = state() |> Tui.wake_cursor() |> Tui.wake_cursor()
    stale = state.blink - 1
    assert {^state, []} = Tui.handle_info({:blink, stale}, state)
  end
end
