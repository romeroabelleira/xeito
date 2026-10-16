defmodule Xeito.Tui.Input do
  @moduledoc """
  Editing the TUI's prompt line: inserting text, pasting, recalling earlier prompts and Tab completion.

  Pure functions over a `TermUI.Widgets.TextInput` state, or over the TUI state's `input`,
  `prompt_history`, `history_index`, `history_draft`, `completion` and `cwd`. Text is inserted
  at the cursor, which ends up after it; a recalled or completed line is edited at its end.
  """

  alias TermUI.Widgets.TextInput
  alias Xeito.Session.Router
  alias Xeito.Tui.SkillSearch

  @own_commands ~w(quit exit statusbar legend sessions skills)

  @doc "Remembers a sent line as the newest prompt, unless it already is, and ends any recall."
  @spec remember(map(), String.t()) :: map()
  def remember(%{prompt_history: [text | _]} = state, text), do: %{state | history_index: -1, history_draft: ""}

  def remember(state, text),
    do: %{state | prompt_history: [text | state.prompt_history], history_index: -1, history_draft: ""}

  @doc "The prompt one step `:older` or `:newer` in the history, and the state recalling it; `:none` past either end."
  @spec recall(map(), :older | :newer) :: {:ok, String.t(), map()} | :none
  def recall(%{history_index: -1, prompt_history: [newest | _]} = state, :older),
    do: {:ok, newest, %{state | history_index: 0, history_draft: TextInput.get_value(state.input)}}

  def recall(%{history_index: i, prompt_history: history} = state, :older) when i >= 0 and i + 1 < length(history),
    do: {:ok, Enum.at(history, i + 1), %{state | history_index: i + 1}}

  def recall(%{history_index: i} = state, :newer) when i >= 0 do
    text = if i == 0, do: state.history_draft, else: Enum.at(state.prompt_history, i - 1)
    {:ok, text, %{state | history_index: i - 1}}
  end

  def recall(_state, _direction), do: :none

  @doc "Replaces the input's text, with the cursor at its end."
  @spec put_text(map(), String.t()) :: map()
  def put_text(input, text), do: input |> TextInput.clear() |> insert(text)

  # TextInput inserts only single characters, so pasted text and new lines are inserted here.
  @doc "Applies a key event (`:input`) or inserts text (`:insert`) at the cursor."
  @spec edit(:input | :insert, term(), map()) :: map()
  def edit(:input, event, input), do: event |> TextInput.handle_event(input) |> elem(1)
  def edit(:insert, text, input), do: insert(input, text)

  @doc "Inserts text, line breaks included, at the cursor."
  @spec insert(map(), String.t()) :: map()
  def insert(input, text) do
    before = before_cursor(input) <> text
    lines = String.split(before, "\n")
    value = Enum.join(Enum.take(input.lines, input.cursor_row), "\n") <> sep(input) <> before <> after_cursor(input)

    %{
      TextInput.set_value(input, value)
      | cursor_row: input.cursor_row + length(lines) - 1,
        cursor_col: String.length(List.last(lines))
    }
  end

  defp sep(%{cursor_row: 0}), do: ""
  defp sep(_input), do: "\n"

  @doc "Whether the text before the cursor ends in `\\`, so Enter starts a new line."
  @spec continued?(map()) :: boolean()
  def continued?(input), do: input |> before_cursor() |> String.ends_with?("\\")

  defp before_cursor(input), do: input.lines |> Enum.at(input.cursor_row) |> String.slice(0, input.cursor_col)

  defp after_cursor(input) do
    [line | below] = Enum.drop(input.lines, input.cursor_row)
    Enum.join([String.slice(line, input.cursor_col..-1//1) | below], "\n")
  end

  @doc "Pasted text with `\\n` line breaks and no control characters but tabs: an escape sequence would reach the screen."
  @spec pasted(String.t()) :: String.t()
  def pasted(text), do: text |> String.replace(~r/\r\n?/, "\n") |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, "")

  @doc "Tab: completes the line, or shows the next candidate while Tab repeats."
  @spec complete(map()) :: map()
  def complete(%{completion: {candidates, shown}} = state),
    do: show(state, candidates, rem(shown + 1, length(candidates)))

  def complete(state) do
    case state.input |> TextInput.get_value() |> completions(state.cwd) do
      [] -> state
      candidates -> show(state, candidates, 0)
    end
  end

  defp show(state, candidates, i),
    do: %{state | input: put_text(state.input, Enum.at(candidates, i)), completion: {candidates, i}}

  @doc "The commands Tab completes: the daemon's and the TUI's own."
  @spec commands() :: [String.t()]
  def commands, do: Enum.sort(@own_commands ++ Xeito.Session.commands())

  defp completions("/machine " <> part, _cwd), do: matching("/machine ", Map.keys(Router.machines()), part)
  defp completions("/skill:" <> part, cwd), do: Enum.map(SkillSearch.completions(part, cwd), &("/skill:" <> &1))
  defp completions("/" <> part, _cwd), do: matching("/", commands(), part)
  defp completions(_line, _cwd), do: []

  defp matching(lead, names, part) do
    part = String.downcase(part)
    for name <- Enum.sort(names), String.starts_with?(String.downcase(name), part), do: lead <> name
  end
end
