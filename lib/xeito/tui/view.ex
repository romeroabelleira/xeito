defmodule Xeito.Tui.View do
  @moduledoc """
  The TUI's screen, drawn from its state as a TermUI render tree.

  Top to bottom: a header naming the machine, the transcript wrapped at the screen's width
  (scrolled up by `scroll` lines), a running command's tail, queued lines, the prompt between
  two borders (up to `prompt_rows/0` rows around the cursor), the optional status bar and the
  status line (`Xeito.Tui.StatusLine`). The tree is exactly `height` rows. Pure: nothing is
  drawn here, only described.
  """

  import TermUI.Component.Helpers

  alias TermUI.Component.RenderNode
  alias TermUI.Renderer.Style
  alias TermUI.Widgets.TextInput
  alias Xeito.Client.StatusBar
  alias Xeito.Tui.StatusLine
  alias Xeito.Tui.Transcript

  @placeholder "ask, or /help"
  @prompt_rows 6

  @doc "The whole screen."
  @spec view(map()) :: RenderNode.t()
  def view(state) do
    bar =
      with true <- state.bar,
           line when line != "" <-
             StatusBar.line(state.usage, state.monitor, state.workspace, state.hidden, state.width - 1) do
        [line]
      else
        _ -> []
      end

    live = for line <- Transcript.live_lines(state), do: pad("   │ " <> line, state.width)
    queued = queue_rows(state)
    prompt = prompt_lines(state, state.width)
    body_height = max(state.height - 4 - length(prompt) - length(bar) - length(live) - length(queued), 1)

    stack(:vertical, [
      text(
        pad(" xeito · #{state.machine || "ready"}", state.width),
        header_style()
      ),
      stack(:vertical, Enum.map(visible(state, body_height), &line_node/1)),
      stack(:vertical, Enum.map(live, &text(&1, Style.new(attrs: [:dim])))),
      stack(:vertical, Enum.map(queued, &text(pad(&1, state.width), Style.new(attrs: [:dim])))),
      border(state.width),
      stack(:vertical, prompt),
      border(state.width),
      stack(:vertical, Enum.map(bar, &text(pad(" " <> &1, state.width), bar_style()))),
      text(StatusLine.line(state, state.width), status_style(state))
    ])
  end

  @doc "The hint an empty prompt shows."
  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  defp queue_rows(%{queue: []}), do: []
  defp queue_rows(%{held: false, queue: queue}), do: Enum.map(queue, &" ⏸ queued: #{one_line(&1)}")

  defp queue_rows(%{held: reason, queue: [first | rest]}),
    do: [
      " ⏸ held (#{held_because(reason)}): #{one_line(first)} · Enter sends · Esc drops"
      | Enum.map(rest, &" ⏸ held: #{one_line(&1)}")
    ]

  @doc "A text's first line, with how many lines follow it."
  @spec one_line(String.t()) :: String.t()
  def one_line(text) do
    case String.split(text, "\n") do
      [line] -> line
      [line | more] -> "#{line} (+#{length(more)} lines)"
    end
  end

  defp held_because("question"), do: "the turn asked you something"
  defp held_because("stopped"), do: "the turn stopped at its step limit"
  defp held_because(status), do: "the turn #{status}"

  @doc "How many rows the prompt grows to before it scrolls."
  @spec prompt_rows() :: pos_integer()
  def prompt_rows, do: @prompt_rows

  @doc "The prompt's rows in `width` columns, each after its mark: `>` first, arrows where lines are hidden."
  @spec prompt_lines(map(), pos_integer()) :: [RenderNode.t()]
  def prompt_lines(state, width) do
    %{lines: lines, cursor_row: row} = state.input
    first = max(row - (@prompt_rows - 1), 0)
    last = min(first + @prompt_rows, length(lines)) - 1

    for i <- first..last do
      line =
        if i == row, do: input_line(state, width - 2), else: text(String.slice(shown(Enum.at(lines, i)), 0, width - 2))

      stack(:horizontal, [text(mark(i, first, last, length(lines))), line])
    end
  end

  defp mark(0, _first, _last, _count), do: "> "
  defp mark(i, i, _last, _count), do: "↑ "
  defp mark(i, _first, i, count) when i < count - 1, do: "↓ "
  defp mark(_i, _first, _last, _count), do: "  "

  # A tab takes one cell, so the cursor's column is the character's.
  defp shown(line), do: String.replace(line, "\t", " ")

  # TextInput's own cursor cannot be restyled, so the cursor is drawn here.
  @doc "The cursor's line in `width` columns, scrolled to keep the cursor, drawn as a block while `cursor_on`."
  @spec input_line(map(), pos_integer()) :: RenderNode.t()
  def input_line(state, width) do
    value = state.input.lines |> Enum.at(state.input.cursor_row) |> shown()
    col = min(state.input.cursor_col, String.length(value))
    start = max(col - (width - 1), 0)
    shown = String.slice(value, start, width)
    {before, rest} = String.split_at(shown, col - start)
    {at, after_cursor} = if rest == "", do: {" ", ""}, else: String.split_at(rest, 1)

    hint =
      if TextInput.get_value(state.input) == "",
        do: [text(" " <> String.slice(@placeholder, 0, max(width - 2, 0)), placeholder_style())],
        else: []

    stack(
      :horizontal,
      [text(before), text(at, if(state.cursor_on, do: cursor_style())), text(after_cursor)] ++ hint
    )
  end

  defp cursor_style, do: Style.new(fg: :black, bg: :yellow)
  defp placeholder_style, do: Style.new(attrs: [:dim])

  @doc "A transcript line; a marked one gets its coloured dot and dim superscript."
  @spec line_node(String.t() | {:marked, atom(), String.t(), String.t()}) :: RenderNode.t()
  def line_node({:marked, color, small, text}),
    do: stack(:horizontal, [text("●", Style.new(fg: color)), text(small, Style.new(attrs: [:dim])), text(" " <> text)])

  def line_node(text) when is_binary(text), do: text(text)

  defp visible(state, height) do
    lines = state.lines ++ if(state.partial == "", do: [], else: [state.partial])
    wrapped = Enum.flat_map(lines, &wrap(&1, state.width))

    shown =
      wrapped
      |> Enum.drop(-min(state.scroll, max(length(wrapped) - height, 0)))
      |> Enum.take(-height)

    shown ++ List.duplicate("", height - length(shown))
  end

  # A marked line wraps after its gutter; its continuation lines are indented to match.
  defp wrap({:marked, color, small, text}, width) do
    gutter = 2 + String.length(small)
    [first | rest] = wrap(text, max(width - gutter, 1))
    [{:marked, color, small, first} | Enum.map(rest, &(String.duplicate(" ", gutter) <> &1))]
  end

  defp wrap("", _width), do: [""]

  defp wrap(line, width) when width > 0 do
    line
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp pad(text, width), do: text |> String.slice(0, width) |> String.pad_trailing(width)

  defp border(width), do: text(String.duplicate("─", width), Style.new(attrs: [:dim]))

  defp header_style, do: Style.new(attrs: [:reverse])
  defp bar_style, do: Style.new(fg: :cyan)

  defp status_style(%{waiting: waiting, paused: paused}) when waiting or paused, do: Style.new(fg: :black, bg: :yellow)
  defp status_style(_state), do: Style.new(attrs: [:dim])
end
