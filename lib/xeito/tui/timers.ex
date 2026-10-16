defmodule Xeito.Tui.Timers do
  @moduledoc """
  The TUI's two timers, the cursor's blink and the working spinner, which run only while needed.

  Each timer sends `{:blink, gen}` or `{:spin, gen}` to the calling process; only a tick of the
  latest generation (`blink`, `spin_gen` in the state) counts, so older ones are stale. The
  cursor blinks for 10 s after the last key, then stays solid (`cursor_on`) and its timer stops.
  The spinner advances `frame` while a run works, and stops at the first tick after it waits,
  pauses, ends or loses the daemon.
  """

  @blink_ms 530
  @blink_for_ms 10_000
  @spin_ms 100

  @doc "A key was pressed: the cursor shows and blinks again, on a new timer generation."
  @spec wake_cursor(map()) :: map()
  def wake_cursor(state) do
    gen = state.blink + 1
    Process.send_after(self(), {:blink, gen}, @blink_ms)
    %{state | cursor_on: true, blink: gen, blink_until: now() + @blink_for_ms}
  end

  @doc "Starts the spinner's timer if the run works and it is not running yet."
  @spec spin(map()) :: map()
  def spin(%{spinning: false} = state) do
    if working?(state) do
      gen = state.spin_gen + 1
      Process.send_after(self(), {:spin, gen}, @spin_ms)
      %{state | spinning: true, spin_gen: gen}
    else
      state
    end
  end

  def spin(state), do: state

  @doc "A timer's tick: the next blink or spinner frame; a stale generation changes nothing."
  @spec tick(:blink | :spin, integer(), map()) :: map()
  def tick(:blink, gen, %{blink: gen} = state), do: blink(gen, state)
  def tick(:spin, gen, %{spin_gen: gen} = state), do: spin_tick(gen, state)
  def tick(_timer, _gen, state), do: state

  defp spin_tick(gen, state) do
    if working?(state) do
      Process.send_after(self(), {:spin, gen}, @spin_ms)
      %{state | frame: state.frame + 1}
    else
      %{state | spinning: false}
    end
  end

  defp working?(state), do: state.leaf not in ["idle", "disconnected"] and not state.waiting and not state.paused

  defp blink(gen, state) do
    if now() < state.blink_until do
      Process.send_after(self(), {:blink, gen}, @blink_ms)
      %{state | cursor_on: not state.cursor_on}
    else
      %{state | cursor_on: true}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
