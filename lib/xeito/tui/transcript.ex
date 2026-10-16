defmodule Xeito.Tui.Transcript do
  @moduledoc """
  The TUI's transcript and run tracking: text and daemon events applied to the TUI state.

  Pure functions, state in and state out. `append/2` adds text to `lines` (at most 5,000), the
  unfinished last line kept in `partial`; a pending Risk `marker` goes on the next complete line
  that is not a state line, as `{:marked, colour, superscript, text}`. `apply_event/2` also
  tracks the run for the status line (`machine`, `leaf`, `started`, `decisions`, `tier`, `usd`,
  `waiting`, `paused`, `queue`, `held`, `usage`) and keeps a running command's last lines in
  `live` and `live_partial` until the command or the turn ends.
  """

  alias TermUI.Widgets.TextInput
  alias Xeito.Client.Render
  alias Xeito.Client.StatusBar

  @max_lines 5_000
  @live_rows 5

  @risk_colors %{"safe" => :green, "review" => :yellow, "abstain" => :yellow, "forbidden" => :red}

  @risk_meanings [
    {"safe", "runs without asking"},
    {"review", "waits for you: y, n, s or a (allow it for this session, or always), or say what to do instead"},
    {"abstain", "no decider was sure: waits for you too"},
    {"forbidden", "refused, never runs"}
  ]

  @progress ["run_selected", "state_entered", "decision_made", "intent"]

  @doc "Appends text to the transcript; a line is complete once its newline arrives."
  @spec append(map(), String.t()) :: map()
  def append(state, ""), do: state

  def append(state, text) do
    [first | rest] = String.split(state.partial <> text, "\n")

    case Enum.split(rest, -1) do
      {[], []} ->
        %{state | partial: first}

      {complete, [partial]} ->
        {complete, state} = mark([first | complete], state)
        lines = Enum.take(state.lines ++ complete, -@max_lines)
        %{state | lines: lines, partial: partial}
    end
  end

  # A pending risk marker goes on the next complete line that is not a state line (`· …`).
  defp mark(lines, %{marker: {color, small}} = state) do
    case Enum.find_index(lines, &(not (&1 |> String.trim_leading() |> String.starts_with?("·")))) do
      nil ->
        {lines, state}

      i ->
        marked = {:marked, color, small, lines |> Enum.at(i) |> String.trim_leading()}
        {List.replace_at(lines, i, marked), %{state | marker: nil}}
    end
  end

  defp mark(lines, state), do: {lines, state}

  @doc "`/legend`: what the risk dots mean, appended to the transcript; the input clears."
  @spec legend(map()) :: map()
  def legend(state) do
    dots = for {value, meaning} <- @risk_meanings, do: {:marked, @risk_colors[value], "", "#{value} · #{meaning}"}
    number = {:marked, @risk_colors["safe"], superscript(94), "the small number · how sure the decider was, in percent"}
    lines = ["Risk: the dot beside each command"] ++ dots ++ [number, ""]
    %{state | input: TextInput.clear(state.input), lines: Enum.take(state.lines ++ lines, -@max_lines)}
  end

  @doc "Applies a daemon event; a Risk decision becomes a coloured dot in the gutter of the line it applies to."
  @spec apply_event(map(), map()) :: map()
  def apply_event(state, %{"event" => "decision_made", "attrs" => %{"decision_type" => type} = a} = event)
      when type in ["Xeito.Decisions.Risk", "Elixir.Xeito.Decisions.Risk"] do
    track(%{state | usage: StatusBar.count(state.usage, event), marker: risk_marker(a)}, "decision_made", event)
  end

  def apply_event(state, %{"event" => "output", "attrs" => %{"text" => text}}), do: live(state, text)

  def apply_event(state, %{"event" => type} = event) do
    %{state | usage: StatusBar.count(state.usage, event)}
    |> track(type, event)
    |> settle_live(type)
    |> append(Render.line(event))
  end

  @doc "A running command's last lines, without colours, the line being written included."
  @spec live_lines(map()) :: [String.t()]
  def live_lines(state) do
    partial = plain(state.live_partial)
    lines = if partial == "", do: state.live, else: state.live ++ [partial]
    Enum.take(lines, -@live_rows)
  end

  defp live(state, text) do
    {complete, [partial]} = (state.live_partial <> text) |> String.split("\n") |> Enum.split(-1)
    %{state | live: Enum.take(state.live ++ Enum.map(complete, &plain/1), -@live_rows), live_partial: partial}
  end

  defp settle_live(state, type) when type in ~w(effect_requested effect_completed turn_finished disconnected),
    do: %{state | live: [], live_partial: ""}

  defp settle_live(state, _type), do: state

  # No colours; a line redrawn with `\r` (a progress bar) keeps its latest state.
  defp plain(line) do
    line
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    |> String.trim_trailing("\r")
    |> String.split("\r")
    |> List.last()
  end

  defp risk_marker(a) do
    value = to_string(a["value"])
    conf = if is_number(a["confidence"]), do: round(a["confidence"] * 100)
    {Map.get(@risk_colors, value, :white), superscript(conf)}
  end

  defp superscript(nil), do: ""

  defp superscript(n),
    do:
      n
      |> Integer.to_string()
      |> String.graphemes()
      |> Enum.map_join(&Enum.at(~w(⁰ ¹ ² ³ ⁴ ⁵ ⁶ ⁷ ⁸ ⁹), String.to_integer(&1)))

  defp track(state, type, event) when type in @progress, do: progress(state, type, event)
  defp track(state, type, event) when type in ["queued", "dequeued", "queue_held"], do: queued(state, type, event)
  defp track(state, type, _event), do: turn_status(state, type)

  defp progress(state, "run_selected", %{"attrs" => a}),
    do: %{state | machine: short(a["machine"]), started: now(), decisions: 0, usd: 0.0}

  defp progress(state, "state_entered", %{"run" => run, "attrs" => %{"state" => leaf}}) do
    if internal?(run), do: state, else: %{state | leaf: to_string(leaf)}
  end

  defp progress(state, "decision_made", %{"attrs" => a}),
    do: %{state | decisions: state.decisions + 1, tier: a["actor"], usd: state.usd + usd(a["usd"])}

  defp progress(state, "intent", %{"attrs" => a}),
    do: %{state | decisions: state.decisions + 1, leaf: "intent", tier: a["actor"]}

  defp queued(state, "queued", %{"attrs" => %{"text" => text}}), do: %{state | queue: state.queue ++ [text]}
  defp queued(state, "queue_held", %{"attrs" => %{"reason" => reason}}), do: %{state | held: reason}

  defp queued(state, "dequeued", _event) do
    queue = Enum.drop(state.queue, 1)
    %{state | queue: queue, held: queue != [] and state.held}
  end

  defp usd(usd) when is_number(usd), do: usd
  defp usd(_usd), do: 0.0

  defp turn_status(state, "human_needed"), do: %{state | waiting: true}
  defp turn_status(state, "paused"), do: %{state | paused: true}
  defp turn_status(state, "turn_finished"), do: %{state | leaf: "idle", waiting: false, paused: false, started: nil}
  defp turn_status(state, "disconnected"), do: %{state | leaf: "disconnected"}
  defp turn_status(state, _type), do: state

  defp internal?(run), do: String.ends_with?(run, "/esc") or String.ends_with?(run, "/intent")

  defp short(nil), do: nil
  defp short(module), do: module |> to_string() |> String.split(".") |> List.last()

  defp now, do: System.monotonic_time(:millisecond)
end
