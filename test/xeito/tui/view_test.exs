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
    # The block sits right after the text, on a space, with nothing after it.
    assert %{children: [%{content: "hello"}, %{content: " ", style: %{bg: :yellow}}, %{content: ""}]} =
             View.input_line(typed(state(), "hello"), 20)

    # An empty line shows the dimmed placeholder.
    assert inspect(View.input_line(state(), 20)) =~ "ask, or /help"

    # A line longer than the width scrolls so that the cursor stays in the last column.
    long = typed(state(), String.duplicate("x", 30) <> "END")
    assert %{children: [%{content: before}, %{content: " ", style: %{bg: :yellow}}, _]} = View.input_line(long, 20)
    assert String.length(before) == 19 and String.ends_with?(before, "END")
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
