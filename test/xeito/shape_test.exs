defmodule Xeito.ShapeTest do
  use Xeito.Case, async: true

  alias Xeito.{Effect, Log, Tools}
  alias Xeito.Effects.Local
  alias Xeito.Log.Event
  alias Xeito.Tools.Shape

  defp bash(cmd, output, status \\ 0) do
    effect = %{Effect.bash(cmd) | id: "ses-x/t1/e12"}
    Shape.shape(effect, %{exit_status: status, output: output})
  end

  test "short output is left alone" do
    result = bash("ls", "a.txt\nb.txt\n")
    refute Map.has_key?(result, :shaped)
    assert Tools.result_text(result) == "exit status 0\na.txt\nb.txt\n"
  end

  test "escape codes and progress redraws go, similar lines collapse" do
    progress = Enum.map_join(1..50, "\n", &"\e[32mCompiling #{&1} of 50 files\e[0m")
    redraw = "Downloading 10%\rDownloading 55%\rDownloading 100%"
    %{shaped: shaped} = bash("mix compile", progress <> "\n" <> redraw <> "\nGenerated app\n")

    refute shaped =~ "\e["

    assert shaped =~
             "Compiling 1 of 50 files\nCompiling 2 of 50 files\n… 47 similar lines\nCompiling 50 of 50 files"

    assert shaped =~ "Downloading 100%" and not (shaped =~ "55%")
    assert shaped =~ ~s([shaped: 52 → 6 lines; full output: read with result: "ses-x/t1/e12"])
  end

  test "long output keeps its first and last lines" do
    output =
      Enum.map_join(1..500, "\n", &"line #{&1} #{String.duplicate("x", rem(&1, 7))}y#{&1}z")

    %{shaped: shaped} = bash("cat big.log", output)

    assert shaped =~ "line 1 " and shaped =~ "line 60 " and shaped =~ "line 500 "
    refute shaped =~ "line 61 "
    assert shaped =~ "… 400 lines …"
  end

  test "search results are grouped by file and capped" do
    output =
      Enum.map_join(1..30, "\n", &"lib/a.ex:#{&1}:  x = #{&1}") <>
        "\n" <> Enum.map_join(1..3, "\n", &"lib/b.ex:#{&1}:  y")

    %{shaped: shaped} = bash(~s(grep -rn "x" lib), output)
    assert shaped =~ "lib/a.ex (30 matches)\n  1: x = 1"
    assert shaped =~ "  … 22 more"
    assert shaped =~ "lib/b.ex (3 matches)\n  1: y"

    # One file with -n prints line numbers, not paths: not grouped.
    one = Enum.map_join(1..30, "\n", &"#{&1}:  x = #{&1} #{String.duplicate("q", &1)}")
    refute (bash(~s(grep -n "x" lib/a.ex), one)[:shaped] || "") =~ "matches"
  end

  test "test output keeps failures and the summary" do
    output =
      String.duplicate(".", 300) <>
        "\n" <>
        Enum.map_join(1..60, "\n", &"noise #{&1} #{String.duplicate("n", &1)}") <>
        """

          1) test adds an item (CartTest)
             test/cart_test.exs:12
             Assertion with == failed
             code:  assert Cart.total(c) == 3
             left:  2
             right: 3

        Finished in 0.1 seconds
        12 tests, 1 failure
        """

    %{shaped: shaped} = bash("mix test", output, 2)
    assert shaped =~ "exit status 2"
    assert shaped =~ "1) test adds an item (CartTest)"
    assert shaped =~ "right: 3"
    assert shaped =~ "12 tests, 1 failure"
    refute shaped =~ "noise 30"
  end

  describe "reads" do
    setup do
      ws = Path.join(System.tmp_dir!(), "xeito-shape-#{System.unique_integer([:positive])}")
      File.mkdir_p!(ws)
      on_exit(fn -> File.rm_rf(ws) end)

      big =
        "defmodule Big do\n" <>
          Enum.map_join(1..300, "\n", &"  def f#{&1}(x) do\n    x + #{&1}\n  end") <> "\nend\n"

      File.write!(Path.join(ws, "big.ex"), big)
      %{ws: ws}
    end

    test "a large file reads as its outline and first lines; a range reads as asked", %{ws: ws} do
      run = fn args ->
        {:ok, effect} = Tools.to_effect(%{name: "read", arguments: args}, %{cwd: ws})
        Tools.result_text(Local.run(effect, []))
      end

      shaped = run.(%{"path" => "big.ex"})
      assert shaped =~ "big.ex · 903 lines"
      assert shaped =~ "  def f300/1  899-901"
      assert shaped =~ ~s(read a definition with symbol, or a range with lines: "121-420")
      refute shaped =~ "x + 200"

      range = run.(%{"path" => "big.ex", "lines" => "599-601"})
      assert range == "big.ex lines 599-601 of 903:\n  def f200(x) do\n    x + 200\n  end"
      assert run.(%{"path" => "big.ex", "lines" => "2000"}) =~ "outside big.ex"
    end

    test "result reads back the full output of an earlier call from the log" do
      log = start_log!()

      output =
        Enum.map_join(1..300, "\n", &"line #{&1} #{String.duplicate("v", rem(&1, 9))}w#{&1}")

      result = bash("cat big.log", output)
      assert result.shaped

      Log.append(log, "ses-x/t1", [
        Event.new("effect_completed", {:effect_completed, "ses-x/t1/e12", result}, %{
          "effect_id" => "ses-x/t1/e12"
        })
      ])

      {:ok, effect} =
        Tools.to_effect(%{name: "read", arguments: %{"result" => "e12"}}, %{cwd: "/w"})

      back = Local.run(effect, log: log, run_id: "ses-x/t1")
      assert back.content == "full output of e12:\nexit status 0\n" <> output
      refute Map.has_key?(back, :shaped)

      assert %{ok: false, error: "no result \"e99\"" <> _} =
               Local.run(%{effect | args: %{effect.args | result: "e99"}},
                 log: log,
                 run_id: "ses-x/t1"
               )
    end
  end

  describe "elision" do
    alias Xeito.Machines.Chat

    defp tool(n, opts \\ []) do
      content =
        Keyword.get(opts, :content, "exit status 0\n" <> String.duplicate("line #{n}\n", 60))

      %{role: "tool", tool_name: Keyword.get(opts, :name, "bash"), content: content}
      |> Map.merge(
        if opts[:ref] == false,
          do: %{},
          else: %{ref: "ses-x/t1/e#{n}", about: "output of `cmd #{n}`"}
      )
    end

    defp conversation(tools),
      do:
        [%{role: "system", content: "s"}, %{role: "user", content: "task"}] ++
          Enum.flat_map(tools, &[%{role: "assistant", content: "", tool_calls: []}, &1])

    defp stubbed(messages),
      do: for(%{role: "tool", content: "[elided" <> _} = m <- messages, do: m.ref)

    test "old tool output is elided in batches; the last outputs stay whole" do
      assert stubbed(Chat.elide(conversation(Enum.map(1..9, &tool/1)))) == []

      ten = Chat.elide(conversation(Enum.map(1..10, &tool/1)))
      assert stubbed(ten) == Enum.map(1..6, &"ses-x/t1/e#{&1}")

      # The stubs stay the same until the next batch: the prompt's start is stable.
      fifteen = Chat.elide(conversation(Enum.map(1..15, &tool/1)))
      assert Enum.take(fifteen, 14) == Enum.take(ten, 14)
      assert length(stubbed(Chat.elide(conversation(Enum.map(1..16, &tool/1))))) == 12

      [stub | _] = for %{content: "[elided" <> _} = m <- ten, do: m.content

      assert stub ==
               "[elided to save context: output of `cmd 1` (62 lines). " <>
                 ~s(If you still need it, read with result: "ses-x/t1/e1".])
    end

    test "short output, skill instructions and results without a ref are never elided" do
      tools =
        [tool(1, content: "ok"), tool(2, name: "skill"), tool(3, ref: false)] ++
          Enum.map(4..20, &tool/1)

      stubbed = stubbed(Chat.elide(conversation(tools)))
      refute Enum.any?(stubbed, &(&1 in ["ses-x/t1/e1", "ses-x/t1/e2"]))
      assert length(stubbed) == 12 and hd(stubbed) == "ses-x/t1/e4"
    end

    test "an elided result from an earlier turn reads back by its full id" do
      log = start_log!()
      result = %{exit_status: 0, output: "the original", ref: "ses-x/t1/e3"}

      Log.append(log, "ses-x/t1", [
        Event.new("effect_completed", {:effect_completed, "ses-x/t1/e3", result}, %{
          "effect_id" => "ses-x/t1/e3"
        })
      ])

      {:ok, effect} =
        Tools.to_effect(%{name: "read", arguments: %{"result" => "ses-x/t1/e3"}}, %{cwd: "/w"})

      assert Local.run(effect, log: log, run_id: "ses-x/t2").content ==
               "full output of ses-x/t1/e3:\nexit status 0\nthe original"
    end
  end
end
