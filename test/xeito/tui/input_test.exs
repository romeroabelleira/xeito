defmodule Xeito.Tui.InputTest do
  use ExUnit.Case, async: true

  alias TermUI.Widgets.TextInput
  alias Xeito.Tui.Input

  defp input(text) do
    {:ok, input} = TextInput.init(TextInput.new(width: 40, multiline: true))
    Input.put_text(input, text)
  end

  defp history(prompts, typed), do: %{input: input(typed), prompt_history: prompts, history_index: -1, history_draft: ""}

  test "text is inserted at the cursor, line breaks included, and the cursor ends after it" do
    inserted = "ab" |> input() |> Input.insert("1\n2")
    assert {TextInput.get_value(inserted), inserted.cursor_row, inserted.cursor_col} == {"ab1\n2", 1, 1}
  end

  test "a paste keeps line breaks and tabs, and drops other control characters" do
    assert Input.pasted("a\r\nb\rc\td\e[31m\a") == "a\nb\nc\td[31m"
  end

  test "a backslash before the cursor continues the line" do
    assert Input.continued?(input("fix \\"))
    refute Input.continued?(input("fix"))
  end

  test "recall steps through the history, newest first, and back to the line being typed" do
    state = history(["new", "old"], "draft")
    {:ok, "new", state} = Input.recall(state, :older)
    {:ok, "old", state} = Input.recall(state, :older)
    assert Input.recall(state, :older) == :none
    {:ok, "new", state} = Input.recall(state, :newer)
    {:ok, "draft", state} = Input.recall(state, :newer)
    assert Input.recall(state, :newer) == :none
  end

  test "a line is remembered once in a row" do
    state = [] |> history("") |> Input.remember("a") |> Input.remember("a")
    assert state.prompt_history == ["a"]
  end

  test "the commands are the daemon's and the TUI's own" do
    assert Input.commands() == Enum.sort(~w(quit exit statusbar legend sessions skills) ++ Xeito.Session.commands())
  end
end
