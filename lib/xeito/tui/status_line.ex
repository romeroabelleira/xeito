defmodule Xeito.Tui.StatusLine do
  @moduledoc """
  The TUI's bottom line: a marker and the run's state on the left, the workspace and git branch on the right.

  The marker is `○` idle, a spinner frame (`frame`) while working, `◆` waiting for a review or a
  paused run, `✗` without a daemon. The line is exactly `width` columns; when it does not fit,
  the run state is cut first. The workspace is shown from `~` and shortened from the left.
  """

  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @place_max 30

  @doc "The status line in `width` columns."
  @spec line(map(), pos_integer()) :: String.t()
  def line(state, width) do
    right = " #{place(state)} "
    left = " #{marker(state)} " <> run_status(state)
    fit(left, max(width - String.length(right), 1)) <> right
  end

  defp fit(text, room) do
    if String.length(text) <= room, do: String.pad_trailing(text, room), else: String.slice(text, 0, room - 1) <> "…"
  end

  defp marker(%{leaf: "disconnected"}), do: "✗"
  defp marker(%{waiting: waiting, paused: paused}) when waiting or paused, do: "◆"
  defp marker(%{leaf: "idle"}), do: "○"
  defp marker(state), do: Enum.at(@frames, rem(state.frame, length(@frames)))

  defp run_status(state) do
    elapsed =
      if state.started,
        do: " · #{Float.round((now() - state.started) / 1000, 1)} s",
        else: ""

    scroll = if state.scroll > 0, do: " · scrolled", else: ""
    tier = if state.tier, do: " · tier #{state.tier}", else: ""
    cost = if state.usd > 0, do: " · $#{Float.round(state.usd, 4)}", else: ""

    "state #{state.leaf}#{elapsed}#{tier} · #{state.decisions} decisions#{cost}#{waiting_for(state)}#{scroll}"
  end

  defp place(state) do
    branch = get_in(state.workspace || %{}, ["git", "branch"])
    short_path(state.cwd) <> if(branch, do: " (#{branch})", else: "")
  end

  defp short_path(path) do
    home = System.user_home() || "/nonexistent"

    path =
      if path == home or String.starts_with?(path, home <> "/"),
        do: "~" <> String.replace_prefix(path, home, ""),
        else: path

    if String.length(path) <= @place_max, do: path, else: shorten(path)
  end

  defp shorten(path) do
    lead = if String.starts_with?(path, "~/"), do: "~/…/", else: "…/"

    path
    |> Path.split()
    |> Enum.reverse()
    |> Enum.reduce_while([], fn part, kept ->
      if kept == [] or String.length(lead <> Path.join([part | kept])) <= @place_max,
        do: {:cont, [part | kept]},
        else: {:halt, kept}
    end)
    |> then(&(lead <> Path.join(&1)))
  end

  defp waiting_for(%{waiting: true}), do: " · review: y / n / s / a"
  defp waiting_for(%{paused: true}), do: " · paused: Enter steps"
  defp waiting_for(_state), do: ""

  defp now, do: System.monotonic_time(:millisecond)
end
