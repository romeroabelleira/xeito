defmodule Xeito.Session.HistoryTest do
  use ExUnit.Case, async: true

  alias Xeito.Chat.Window
  alias Xeito.Machines.Chat
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Machines.RunTests
  alias Xeito.Session.History

  defp messages(n), do: for(i <- 1..n, do: %{role: if(rem(i, 2) == 1, do: "user", else: "assistant"), content: "m#{i}"})

  test "up to 80 messages stay; past that, the last 60" do
    assert History.trim(messages(80)) == messages(80)
    assert History.trim(messages(81)) == Enum.take(messages(81), -60)
  end

  test "a summary of earlier turns stays first when the window is trimmed" do
    summary = Window.summary_message("Goal: x.", messages(30))
    assert [^summary | rest] = History.trim([summary | messages(85)])
    assert rest == Enum.take(messages(85), -59)
  end

  describe "settled/1: a halted turn's messages, without unanswered tool calls" do
    defp calls(n), do: %{role: "assistant", content: "", tool_calls: List.duplicate(%{name: "bash"}, n)}
    defp tool, do: %{role: "tool", content: "ok"}

    test "complete exchanges are kept" do
      done = [%{role: "user", content: "p"}, calls(2), tool(), tool(), %{role: "assistant", content: "a"}]
      assert History.settled(done) == done
      assert History.settled([%{role: "user", content: "p"}]) == [%{role: "user", content: "p"}]
    end

    test "the last calls, if not all answered, are dropped with their partial results" do
      before = [%{role: "user", content: "p"}, calls(1), tool()]
      assert History.settled(before ++ [calls(2), tool()]) == before
      assert History.settled(before ++ [calls(1)]) == before
    end
  end

  test "fix_failing_test with nothing failing says so, and how to write a new test instead" do
    passing = %{status: :done, state: :done, ctx: %{test_cmd: "mix test"}}

    assert History.answer(FixFailingTest, passing) ==
             "The tests pass (mix test): there is no failing test to fix. To write a new test, " <>
               "ask for it without saying it fails, or use /machine chat <request>."

    fixed = %{status: :done, state: :done, ctx: %{last_failure: "1 failure", fix: %{answer: "Fixed the rounding."}}}
    assert History.answer(FixFailingTest, fixed) == "fix_failing_test ended in done: Fixed the rounding."
  end

  test "a turn's answer: a shell command's exit, or a machine's error or final state" do
    answer = &History.answer/2
    shell = %{status: :failed, state: :failed, ctx: %{cmd: "make", exit_status: 2}}
    assert answer.(Xeito.Machines.Shell, shell) == "`make` exited 2"

    assert answer.(RunTests, %{status: :done, state: :done, ctx: %{}}) == "Xeito.Machines.RunTests ended in done"
    assert answer.(RunTests, %{status: :failed, state: :failed, ctx: %{error: "no tests"}}) == "no tests"
    assert answer.(RunTests, %{status: :failed, state: :failed, ctx: %{error: :timeout}}) == ":timeout"
    assert answer.(Chat, %{status: :done, state: :answered, ctx: %{answer: "Hi."}}) == "Hi."
    assert answer.(Chat, %{status: :done, state: :failed, ctx: %{error: {:http, 500}}}) == "{:http, 500}"
    assert answer.(RunTests, %{status: :halted, state: :running, ctx: %{}}) == "Halted by the user."
  end
end
