defmodule Xeito.ChatMachineTest do
  @moduledoc "Unit tests of the chat machine's guards and actions, on contexts, without a model."
  use ExUnit.Case, async: true

  alias Xeito.Machines.Chat

  defp call(name, args), do: %{name: name, arguments: args}
  defp message(content, calls \\ []), do: %{content: content, tool_calls: calls}
  defp ctx(extra \\ %{}), do: Map.merge(%{cwd: "/w", prompt: "p", steps: 3}, extra)

  describe "repeated and invalid calls" do
    test "an exact repeat of a call made in this turn is not valid; a different one is" do
      seen = ctx(%{seen: [{"bash", %{"command" => "ls"}}]})
      refute Chat.calls_next_risky?(seen, message("", [call("bash", %{"command" => "ls"})]))
      assert Chat.calls_next_risky?(seen, message("", [call("bash", %{"command" => "pwd"})]))
    end

    test "queue_calls answers a repeat with a pointer to the earlier result and counts the streak" do
      seen = ctx(%{seen: [{"bash", %{"command" => "ls"}}]})
      after_repeat = Chat.queue_calls(seen, message("Again.", [call("bash", %{"command" => "ls"})]))
      assert List.last(after_repeat.turn).content =~ "you already made this exact call"
      assert after_repeat.invalid_streak == 1
      assert Chat.invalid_again?(after_repeat, message("", [call("bash", %{"command" => "ls"})]))

      fresh = Chat.queue_calls(after_repeat, message("New.", [call("bash", %{"command" => "pwd"})]))
      assert fresh.invalid_streak == 0
    end

    test "without tools, a call is answered so, not with an empty list of tools" do
      no_tools = ctx(%{tools: false})
      queued = Chat.queue_calls(no_tools, message("", [call("read", %{"path" => "a"})]))
      assert List.last(queued.turn).content == "error: no tools are available in this turn; answer in text"
    end

    test "a third step opening with the same sentence gets a nudge" do
      twice = ctx(%{openings: ["Since the widget hardcodes the style", "Since the widget hardcodes the style"]})

      queued =
        Chat.queue_calls(
          twice,
          message("Since the widget hardcodes the style. Let me grep.", [call("bash", %{"command" => "pwd"})])
        )

      assert Enum.any?(queued.turn, &(&1.role == "user" and &1.content =~ "going in circles"))

      once = ctx(%{openings: ["Since the widget hardcodes the style"]})

      queued =
        Chat.queue_calls(
          once,
          message("Since the widget hardcodes the style. Again.", [call("bash", %{"command" => "pwd"})])
        )

      refute Enum.any?(queued.turn, &(&1.role == "user" and &1.content =~ "going in circles"))
    end
  end

  describe "stopping and wrapping up" do
    test "guards: stopped, and passed but stopped" do
      assert Chat.stopped?(ctx(%{stopped: true}), nil)
      refute Chat.stopped?(ctx(), nil)
      assert Chat.passed_but_stopped?(ctx(%{stopped: true}), %{exit_status: 0})
      refute Chat.passed_but_stopped?(ctx(%{stopped: true}), %{exit_status: 1})
    end

    test "the wrap-up answer follows the stop notice; an error or an empty reply keeps the notice" do
      stopped = ctx(%{stopped: true, answer: "Stopped after 3 model turns (max_steps)."})
      wrapped = Chat.record_wrap_up(stopped, message("Found it; next, edit tui.ex."))
      assert wrapped.answer == "Stopped after 3 model turns (max_steps).\n\nFound it; next, edit tui.ex."
      assert Chat.record_wrap_up(stopped, %{error: :timeout}) == stopped
      assert Chat.record_wrap_up(stopped, message("  ")).answer == stopped.answer
    end

    test "the wrap-up request asks for a summary without tools, and says why" do
      [effect] = Chat.ask_wrap_up(ctx(%{stop_reason: :invalid}))
      assert effect.args.tools == false
      assert List.last(effect.args.messages).content =~ "could not run"

      [effect] = Chat.ask_wrap_up(ctx(%{stop_reason: :limit}))
      assert List.last(effect.args.messages).content =~ "used all 3 model turns"
    end

    test "an empty final answer is noted" do
      assert Chat.record_answer(ctx(), message("")).answer == "(The model ended this turn without an answer.)"
    end
  end

  describe "what a tool result was (for its stub if elided)" do
    defp about(name, args) do
      %{current: call(name, args), pending: []}
      |> ctx()
      |> Chat.record_result(%{ok: true, content: "x", ref: "ses/t1/e1"})
      |> Map.fetch!(:turn)
      |> List.last()
      |> Map.fetch!(:about)
    end

    test "a shell command, shortened past 80 characters" do
      assert about("bash", %{"command" => "ls"}) == "output of `ls`"
      long = String.duplicate("a", 90)
      assert about("bash", %{"command" => long}) == "output of `" <> String.duplicate("a", 80) <> "…`"
    end

    test "a read, with the part that was read" do
      assert about("read", %{"path" => "lib/a.ex"}) == "read of lib/a.ex"
      assert about("read", %{"path" => "lib/a.ex", "symbol" => "f/1"}) == "read of lib/a.ex (f/1)"
      assert about("read", %{"path" => "lib/a.ex", "lines" => "1-9"}) == "read of lib/a.ex (1-9)"
      assert about("read", %{"path" => "lib/a.ex", "outline" => true}) == "read of lib/a.ex (outline)"
      assert about("read", %{"path" => "", "result" => "ses/t1/e3"}) == "full output of ses/t1/e3"
    end

    test "any other tool" do
      assert about("write", %{"path" => "a", "content" => "b"}) == "write result"
    end
  end

  describe "guards on a model message" do
    defp bad, do: message("", [call("no_such_tool", %{})])
    defp good, do: message("", [call("bash", %{"command" => "ls"})])

    test "only invalid calls: there are calls, and none of them is valid" do
      refute Chat.only_invalid_calls?(ctx(), message("Done."))
      refute Chat.only_invalid_calls?(ctx(), good())
      assert Chat.only_invalid_calls?(ctx(), bad())
    end

    test "invalid again: only invalid calls right after a step with only invalid calls" do
      refute Chat.invalid_again?(ctx(), bad())
      refute Chat.invalid_again?(ctx(%{invalid_streak: 1}), good())
      assert Chat.invalid_again?(ctx(%{invalid_streak: 1}), bad())
    end

    test "invalid again after an edit, which then still gets its checks" do
      edited = %{edited: true, verify: "mix test"}
      refute Chat.invalid_again_edited?(ctx(%{invalid_streak: 1}), bad())
      refute Chat.invalid_again_edited?(ctx(edited), bad())
      assert Chat.invalid_again_edited?(ctx(Map.put(edited, :invalid_streak, 1)), bad())
    end

    test "calls on the last allowed step stop instead of running" do
      refute Chat.calls_at_limit?(ctx(%{max_steps: 5, steps: 4}), message("Done."))
      refute Chat.calls_at_limit?(ctx(%{max_steps: 5, steps: 3}), good())
      assert Chat.calls_at_limit?(ctx(%{max_steps: 5, steps: 4}), good())
    end

    test "the step limit is reached at max_steps" do
      refute Chat.step_limit?(ctx(%{max_steps: 5, steps: 4}), nil)
      assert Chat.step_limit?(ctx(%{max_steps: 5, steps: 5}), nil)
    end

    test "a model call sends the system prompt and the prompt first, then the turn so far" do
      [first] = Chat.ask_model(ctx(%{system: "S"}))
      assert [%{role: "system", content: "S"}, %{role: "user", content: "p"}] = first.args.messages

      turn = [%{role: "system", content: "S"}, %{role: "user", content: "p"}, %{role: "assistant", content: "a"}]
      [later] = Chat.ask_model(ctx(%{turn: turn}))
      assert later.args.messages == turn
    end
  end

  describe "a review answered with text instead of y or n" do
    alias Xeito.Machine
    alias Xeito.Machine.Engine

    defp reviewing(extra \\ %{}) do
      bash = call("bash", %{"command" => "mix test"})
      ctx(Map.merge(%{current: bash, pending: [call("read", %{"path" => "a"})], turn: []}, extra))
    end

    test "the call is not run: the model gets the text as its result, later calls are skipped" do
      told = Chat.instruct(reviewing(), %{text: "use mix test --failed"})

      assert [%{role: "tool", tool_name: "bash", content: first}, %{role: "tool", tool_name: "read", content: second}] =
               Enum.take(told.turn, -2)

      assert first == "not run: instead of approving, the user said: use mix test --failed"
      assert second =~ "skipped"
      assert {told.current, told.pending} == {nil, []}
    end

    test "the machine goes back to the model, or wraps up at the step limit" do
      machine = Machine.fetch!(Chat)
      data = %{text: "no"}
      assert {:ok, %{to: :thinking}} = Engine.handle(machine, :ask_human, reviewing(), :instructed, data)

      assert {:ok, %{to: :wrapping_up, ctx: %{stopped: true}}} =
               Engine.handle(machine, :ask_human, reviewing(%{max_steps: 3, steps: 3}), :instructed, data)
    end
  end
end
