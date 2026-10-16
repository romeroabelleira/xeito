defmodule Xeito.Machines.Chat.ElisionTest do
  use ExUnit.Case, async: true

  alias Xeito.Machines.Chat.Elision

  defp tool(n, opts \\ []) do
    content =
      Keyword.get(opts, :content, "exit status 0\n" <> String.duplicate("line #{n}\n", 60))

    Map.merge(
      %{role: "tool", tool_name: Keyword.get(opts, :name, "bash"), content: content},
      if(opts[:ref] == false, do: %{}, else: %{ref: "ses-x/t1/e#{n}", about: "output of `cmd #{n}`"})
    )
  end

  defp conversation(tools),
    do:
      [%{role: "system", content: "s"}, %{role: "user", content: "task"}] ++
        Enum.flat_map(tools, &[%{role: "assistant", content: "", tool_calls: []}, &1])

  defp stubbed(messages), do: for(%{role: "tool", content: "[elided" <> _} = m <- messages, do: m.ref)

  test "old tool output is elided in batches; the last outputs stay whole" do
    assert stubbed(Elision.elide(conversation(Enum.map(1..9, &tool/1)))) == []

    ten = Elision.elide(conversation(Enum.map(1..10, &tool/1)))
    assert stubbed(ten) == Enum.map(1..6, &"ses-x/t1/e#{&1}")

    # The stubs stay the same until the next batch: the prompt's start is stable.
    fifteen = Elision.elide(conversation(Enum.map(1..15, &tool/1)))
    assert Enum.take(fifteen, 14) == Enum.take(ten, 14)
    assert length(stubbed(Elision.elide(conversation(Enum.map(1..16, &tool/1))))) == 12

    [stub | _] = for %{content: "[elided" <> _} = m <- ten, do: m.content

    assert stub ==
             "[elided to save context: output of `cmd 1` (62 lines). " <>
               ~s(If you still need it, read with result: "ses-x/t1/e1".])
  end

  test "short output, skill instructions and results without a ref are never elided" do
    tools =
      [tool(1, content: "ok"), tool(2, name: "skill"), tool(3, ref: false)] ++
        Enum.map(4..20, &tool/1)

    stubbed = stubbed(Elision.elide(conversation(tools)))
    refute Enum.any?(stubbed, &(&1 in ["ses-x/t1/e1", "ses-x/t1/e2"]))
    assert length(stubbed) == 12 and hd(stubbed) == "ses-x/t1/e4"
  end

  test "the latest whole read of recent project files stays whole; older reads and dependencies are elided" do
    read = fn n, path -> n |> tool() |> Map.put(:read, path) |> Map.put(:about, "read of #{path}") end

    tools =
      [read.(1, "lib/tui.ex"), read.(2, "lib/tui.ex"), 3 |> tool() |> Map.put(:about, "read of deps/x.ex")] ++
        Enum.map(4..15, &tool/1)

    stubbed = stubbed(Elision.elide(conversation(tools)))
    # e2 is the latest read of lib/tui.ex: kept. e1 (an older read of it) and the rest elide.
    refute "ses-x/t1/e2" in stubbed
    assert "ses-x/t1/e1" in stubbed and "ses-x/t1/e3" in stubbed

    # Only the last three project files read keep their latest read.
    many = Enum.map(1..4, &read.(&1, "lib/f#{&1}.ex")) ++ Enum.map(5..16, &tool/1)
    stubbed = stubbed(Elision.elide(conversation(many)))
    assert "ses-x/t1/e1" in stubbed
    refute Enum.any?(2..4, &("ses-x/t1/e#{&1}" in stubbed))
  end
end
