defmodule Xeito.Source.ReadCostTest do
  use ExUnit.Case, async: true

  alias Xeito.Source.ReadCost

  @source ~S'''
  defmodule A do
    @moduledoc """
    Twelve chars
    """

    # a comment
    @doc "One line."
    def a, do: 1
  end
  '''

  test "file/1: tokens of the whole text, and of its prose (docs and comments)" do
    prose = String.length(~s(  @moduledoc """\n  Twelve chars\n  """\n  # a comment\n  @doc "One line."\n))

    assert ReadCost.file(@source) == %{tokens: ceil(String.length(@source) / 4), prose: ceil(prose / 4)}
  end

  test "file/1: code without docs has no prose" do
    assert ReadCost.file("defmodule B do\nend\n").prose == 0
  end

  test "file/1: a doc string that runs over several lines counts to its end" do
    text = ~s(@doc "first\nsecond"\ndef x, do: 1\n)
    assert ReadCost.file(text).prose == ceil(String.length(~s(@doc "first\nsecond"\n)) / 4)
  end

  test "file/1: @doc false and @moduledoc false are not prose" do
    assert ReadCost.file("  @moduledoc false\n  @doc false\n  def x, do: 1\n").prose == 0
  end

  test "file/1: heredocs in single quotes or ~S count to their end" do
    for open <- ["'''", ~s(~S""")] do
      close = if open == "'''", do: "'''", else: ~s(""")
      doc = "  @doc #{open}\n  text\n  #{close}\n"
      assert ReadCost.file(doc <> "  def x, do: 1\n").prose == ceil(String.length(doc) / 4)
    end
  end

  test "file/1: a doc that is not a string literal is one line of prose" do
    line = "  @doc @shared_doc\n"
    assert ReadCost.file(line <> "  def x, do: 1\n").prose == ceil(String.length(line) / 4)
  end

  describe "measure/2 and format/1" do
    setup do
      files = %{"AGENTS.md" => String.duplicate("a", 40), "lib/a.ex" => @source, "test/a_test.exs" => "test\n"}
      {:ok, read: &Map.fetch(files, &1)}
    end

    test "each task costs what is always read plus its own files", %{read: read} do
      set = %{always: ["AGENTS.md"], tasks: [%{name: "change a", files: ["lib/a.ex", "test/a_test.exs"]}]}

      assert %{always: 10, tasks: [%{name: "change a", tokens: tokens, prose: prose, missing: []}], total: total} =
               ReadCost.measure(set, read)

      assert tokens == 10 + ReadCost.file(@source).tokens + 2
      assert prose == ReadCost.file(@source).prose
      assert total == tokens
      assert ReadCost.measure(set, read).prose == prose
    end

    test "a file that is not there is reported, and costs nothing", %{read: read} do
      set = %{always: [], tasks: [%{name: "x", files: ["lib/gone.ex"]}]}
      assert %{tasks: [%{tokens: 0, missing: ["lib/gone.ex"]}]} = ReadCost.measure(set, read)
    end

    test "the report: one row per task, then the total", %{read: read} do
      set = %{always: ["AGENTS.md"], tasks: [%{name: "change a", files: ["lib/a.ex", "lib/gone.ex"]}]}
      text = ReadCost.format(ReadCost.measure(set, read))

      assert text =~ "always read: 10 tokens"
      assert text =~ ~r/change a\s+\d+\s+\d+/
      assert text =~ "missing: lib/gone.ex"
      assert text =~ ~r/total\s+\d+\s+\d+/
    end
  end
end
