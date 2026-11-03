defmodule Xeito.Machines.Chat.CallsTest do
  use ExUnit.Case, async: true

  alias Xeito.Machines.Chat.Calls

  defp call(name, args), do: %{name: name, arguments: args}
  defp ls, do: call("bash", %{"command" => "ls"})
  defp read(path), do: call("read", %{"path" => path})
  defp reply(content \\ "", calls), do: %{content: content, tool_calls: calls}
  defp ctx(extra \\ %{}), do: Map.merge(%{cwd: "/w", prompt: "p"}, extra)

  describe "sort" do
    test "valid calls run in order; invalid ones and repeats are refused with a reason" do
      ctx = ctx(%{seen: [{"bash", %{"command" => "ls"}}]})

      assert {[%{name: "read"}], [{%{name: "no_such_tool"}, "error: " <> _}, {%{name: "bash"}, repeat}]} =
               Calls.sort(reply([call("no_such_tool", %{}), read("a"), ls()]), ctx)

      assert repeat =~ "not run: you already made this exact call"
    end

    test "a repeat within one reply is refused too, and a known result is quoted" do
      assert {[_], [{_, "not run: " <> _}]} = Calls.sort(reply([ls(), ls()]), ctx())

      known = ctx(%{seen: [{"bash", %{"command" => "ls"}}], results: %{{"bash", %{"command" => "ls"}} => "a.ex"}})
      assert {[], [{_, "not run again: " <> rest}]} = Calls.sort(reply([ls()]), known)
      assert rest =~ "Its result:\n\na.ex\n\n"
    end

    test "a reply without calls has none" do
      assert Calls.sort(%{content: "Done."}, ctx()) == {[], []}
      assert Calls.valid(%{content: "Done."}, ctx()) == []
    end
  end

  test "the next call's risk" do
    ctx = %{cwd: "/w"}
    assert Calls.next_is?([ls()], :risk, ctx)
    refute Calls.next_is?([ls()], :run, ctx)
    assert Calls.next_is?([read("a")], :run, ctx)
    refute Calls.next_is?([], :risk, ctx)
    refute Calls.next_is?([], :run, ctx)

    # An MCP tool the annotations do not call safe needs a human, not the Risk decision.
    wipe = %{server: "fx", name: "wipe", description: "", schema: %{}, annotations: %{}, exposure: :direct}
    assert Calls.next_is?([%{name: "fx__wipe", arguments: %{}}], :human, Map.put(ctx, :mcp, [wipe]))
    refute Calls.next_is?([%{name: "fx__wipe", arguments: %{}}], :risk, Map.put(ctx, :mcp, [wipe]))
  end

  describe "remember" do
    test "valid calls become seen, the streak resets, the opening is kept" do
      remembered = Calls.remember(ctx(%{seen: [:old], invalid_streak: 1}), reply("Look. Then edit.", [ls()]), [ls()])
      assert remembered.seen == [{"bash", %{"command" => "ls"}}, :old]
      assert remembered.invalid_streak == 0
      assert remembered.openings == ["Look"]
    end

    test "a reply with no valid call adds to the streak" do
      once = Calls.remember(ctx(), reply("", [ls()]), [])
      assert %{seen: [], invalid_streak: 1, openings: [""]} = once

      assert once |> Calls.remember(reply("Again: x", []), []) |> Map.take([:invalid_streak, :openings]) ==
               %{invalid_streak: 2, openings: ["Again", ""]}
    end
  end

  test "a third reply opening with the same sentence gets a note; an empty opening never does" do
    assert [%{role: "user", content: note}] = Calls.stuck_note(ctx(%{openings: ["Hm", "Hm"]}), reply("Hm. Yes", []))
    assert note =~ "going in circles"
    assert Calls.stuck_note(ctx(%{openings: ["Hm"]}), reply("Hm. Yes", [])) == []
    assert Calls.stuck_note(ctx(%{openings: ["", ""]}), reply("  ", [])) == []
  end

  test "results are kept for repeats until an edit" do
    ctx = ctx(%{current: ls()})
    kept = Calls.remember_result(ctx, %{exit_status: 0, output: "a"})
    assert kept.results == %{{"bash", %{"command" => "ls"}} => "exit status 0\na"}
    assert %{seen: [], results: %{}} = Calls.forget(Map.put(kept, :seen, [:x]))
  end

  test "an edit is a write or edit call that succeeded" do
    assert Calls.edit_done?(%{current: call("write", %{})}, %{ok: true})
    assert Calls.edit_done?(%{current: call("edit", %{})}, %{ok: true})
    refute Calls.edit_done?(%{current: call("edit", %{})}, %{ok: false})
    refute Calls.edit_done?(%{current: read("a")}, %{ok: true})
    refute Calls.edit_done?(%{current: nil}, %{ok: true})
  end
end
