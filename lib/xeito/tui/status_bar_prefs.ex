defmodule Xeito.Tui.StatusBarPrefs do
  @moduledoc """
  The TUI's `/statusbar` command and Ctrl-T: whether the status bar shows, and which segments it hides.

  Showing the bar turns the daemon's monitor on (hiding it, off). `/statusbar` saves its change
  in the preferences file (`prefs_file`); a preference that cannot be saved still applies for
  this session, with a line saying so. Returns the TUI state.

    * `/statusbar`, `on`, `off`: toggle, show or hide the bar
    * `reset`: show the bar with every segment
    * `show|hide <segment>[,<segment>]`, `segments`: choose segments, or list them
  """

  alias Xeito.Client.Config
  alias Xeito.Client.StatusBar
  alias Xeito.Tui
  alias Xeito.Tui.Transcript

  @doc "Shows or hides the status bar, and turns the daemon's monitor on or off with it; not saved."
  @spec set_bar(map(), boolean()) :: map()
  def set_bar(state, bar) do
    Tui.request(state, %{"cmd" => "monitor", "on" => bar})
    %{state | bar: bar, monitor: if(bar, do: state.monitor)}
  end

  @doc "Runs `/statusbar` with its words."
  @spec command([String.t()], map()) :: map()
  def command(args, state) when args in [[], ["on"], ["off"]], do: state |> set_bar(visible?(args, state)) |> save()

  def command(["reset"], state), do: save(%{set_bar(state, true) | hidden: []})

  def command([verb | names], state) when verb in ["show", "hide"] and names != [], do: set_segments(verb, names, state)

  def command(["segments"], state), do: list_segments(state)

  def command(_args, state),
    do: Transcript.append(state, "/statusbar [on|off|reset|segments] · /statusbar show|hide <segment>[,<segment>]\n")

  defp visible?([], state), do: not state.bar
  defp visible?(["on"], _state), do: true
  defp visible?(["off"], _state), do: false

  defp set_segments(verb, names, state) do
    case names -- StatusBar.segments() do
      [] -> save(%{state | hidden: hidden(verb, names, state.hidden)})
      unknown -> Transcript.append(state, "✗ unknown segment #{Enum.join(unknown, ", ")}; see /statusbar segments\n")
    end
  end

  defp hidden("hide", names, hidden), do: Enum.uniq(hidden ++ names)
  defp hidden("show", names, hidden), do: hidden -- names

  defp list_segments(state) do
    listed = Enum.map_join(StatusBar.segments(), " ", &if(&1 in state.hidden, do: "·#{&1}", else: &1))
    Transcript.append(state, "status bar #{if state.bar, do: "on", else: "off"} · segments: #{listed} (· hidden)\n")
  end

  defp save(state) do
    prefs = put_in(state.prefs, ["status_bar"], %{"visible" => state.bar, "hidden" => state.hidden})

    case Config.save(prefs, state.prefs_file) do
      :ok ->
        %{state | prefs: prefs}

      {:error, reason} ->
        Transcript.append(%{state | prefs: prefs}, "✗ could not save preferences: #{inspect(reason)}\n")
    end
  end
end
