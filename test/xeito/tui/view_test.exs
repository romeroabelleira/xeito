defmodule Xeito.Tui.ViewTest do
  use ExUnit.Case, async: true

  alias TermUI.Widgets.TextInput
  alias Xeito.Tui.View

  defp state do
    {:ok, input} = TextInput.init(TextInput.new(width: 20))
    %{input: TextInput.set_focused(input, true), cursor_on: true, blink: 0, blink_until: 0}
  end

  defp cursor_drawn?(state), do: state |> View.input_line(20) |> inspect() =~ "bg: :yellow"

  defp typed(state, text) do
    Enum.reduce(String.graphemes(text), state, fn c, st ->
      {:ok, input} = TextInput.handle_event(%TermUI.Event.Key{key: c, char: c}, st.input)
      %{st | input: input}
    end)
  end

  test "the input line draws a block cursor at the typing position and scrolls to keep it visible" do
    st = typed(state(), "hello")
    line = inspect(View.input_line(st, 20))
    # The block sits after the text, on a space; an empty line shows the dimmed placeholder.
    assert line =~ ~s(content: "hello") and line =~ "bg: :yellow"
    assert inspect(View.input_line(state(), 20)) =~ "ask, or /help"

    long = typed(state(), String.duplicate("x", 30) <> "END")
    shown = long |> View.input_line(20) |> inspect()
    assert shown =~ "END" and not (shown =~ String.duplicate("x", 20))
  end

  test "in the blink's off phase the cursor cell is drawn plain" do
    st = typed(state(), "ab")
    assert cursor_drawn?(st)
    refute cursor_drawn?(%{st | cursor_on: false})
    assert inspect(View.input_line(%{st | cursor_on: false}, 20)) =~ ~s(content: "ab")
  end

  test "a marked line renders a coloured dot, a dim superscript and the text" do
    node = inspect(View.line_node({:marked, :red, "¹⁰⁰", "$ rm -rf /"}))
    assert node =~ ~s(content: "●") and node =~ "fg: :red"
    assert node =~ ~s(content: "¹⁰⁰") and node =~ ":dim"
    assert node =~ ~s(content: " $ rm -rf /")
  end
end
