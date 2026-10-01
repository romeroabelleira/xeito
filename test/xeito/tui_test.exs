defmodule Xeito.TuiTest do
  use ExUnit.Case, async: true

  alias TermUI.Widgets.TextInput
  alias Xeito.Tui

  defp state do
    {:ok, input} = TextInput.init(TextInput.new(width: 20))
    %{input: TextInput.set_focused(input, true), cursor_on: true, blink: 0, blink_until: 0}
  end

  defp cursor_drawn?(state),
    do: state |> Tui.input_view() |> TextInput.render(%{width: 20, height: 1}) |> inspect() =~ ":reverse"

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

  test "a newer key makes older blink timers stale" do
    state = state() |> Tui.wake_cursor() |> Tui.wake_cursor()
    stale = state.blink - 1
    assert {^state, []} = Tui.handle_info({:blink, stale}, state)
  end
end
