defmodule Xeito.ChatMachineTest do
  @moduledoc "Unit tests of the chat machine's guards and actions, on contexts, without a model."
  use ExUnit.Case, async: true

  alias Xeito.Machine
  alias Xeito.Machine.Engine
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

  describe "a model that repeats itself before changing anything" do
    defp ran_ls do
      ctx()
      |> Chat.queue_calls(message("Look.", [call("bash", %{"command" => "ls"})]))
      |> Chat.record_result(%{exit_status: 0, output: "banner.ex\n"})
    end

    test "a repeat is answered with the earlier result, without running it again" do
      repeated = Chat.queue_calls(ran_ls(), message("Again.", [call("bash", %{"command" => "ls"})]))

      assert %{role: "tool", content: content} = List.last(repeated.turn)
      assert content =~ "not run again: you already made this exact call in this turn. Its result:"
      assert content =~ "banner.ex"
      assert repeated.pending == [] and repeated.invalid_streak == 1
    end

    test "the second step of repeats in a turn that changed nothing gets one nudge, with tools" do
      machine = Machine.fetch!(Chat)
      repeat = message("", [call("bash", %{"command" => "ls"})])
      once = Chat.queue_calls(ran_ls(), repeat)

      assert {:ok, %{to: :thinking, ctx: nudged}} = Engine.handle(machine, :thinking, once, :chatted, repeat)
      assert nudged.nudged
      assert %{role: "user", content: nudge} = List.last(nudged.turn)
      assert nudge =~ "You already have the results you need"

      # Still repeating after the nudge: the turn ends.
      assert {:ok, %{to: :wrapping_up, ctx: %{stopped: true}}} =
               Engine.handle(machine, :thinking, nudged, :chatted, repeat)
    end

    test "a turn that already edited, or was already nudged, is not nudged" do
      machine = Machine.fetch!(Chat)
      bad = message("", [call("no_such_tool", %{})])

      assert {:ok, %{to: :wrapping_up}} =
               Engine.handle(machine, :thinking, ctx(%{invalid_streak: 1, nudged: true}), :chatted, bad)

      assert {:ok, %{to: :wrapping_up}} =
               Engine.handle(machine, :thinking, ctx(%{invalid_streak: 1, edited: true}), :chatted, bad)
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
      assert about("read", %{"path" => "lib/a.ex", "outline" => false}) == "read of lib/a.ex"
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

  describe "the context window" do
    defp long_history(turns, chars) do
      Enum.flat_map(1..turns, fn n ->
        [%{role: "user", content: "request #{n}"}, %{role: "assistant", content: String.duplicate("a", chars)}]
      end)
    end

    test "a request that fits is sent as it is" do
      [effect] = Chat.ask_model(ctx(%{system: "S", messages: long_history(2, 10)}))
      assert [%{role: "system", content: "S"}, %{content: "request 1"} | _] = effect.args.messages
      refute Map.has_key?(effect.args, :error)
    end

    test "earlier turns are dropped to fit the context, the system prompt and the prompt stay" do
      # A context of 12k tokens leaves 12_288 - 8_192 = 4_096 for the request: 20 turns of 1k don't fit.
      [effect] = Chat.ask_model(ctx(%{system: "S", context: 12_288, messages: long_history(20, 1_000)}))
      assert [%{role: "system", content: "S"}, %{content: "[" <> note} | _] = effect.args.messages
      assert note =~ "earlier messages omitted"
      assert List.last(effect.args.messages) == %{role: "user", content: "p"}
    end

    test "a system prompt that does not fit is not sent: the turn fails with the reason" do
      [effect] = Chat.ask_model(ctx(%{system: String.duplicate("s", 30_000), context: 12_288}))
      assert {:system_too_large, _tokens, 4_096} = effect.args.error
    end

    test "the wrap-up request is fitted too" do
      [effect] = Chat.ask_wrap_up(ctx(%{system: "S", context: 12_288, messages: long_history(20, 1_000)}))
      assert [%{role: "system"}, %{content: "[" <> _} | _] = effect.args.messages
    end

    test "the server's token count calibrates the next estimate" do
      # The request answered was the system prompt (3_000 characters) and the prompt ("p").
      sent = ctx(%{system: String.duplicate("s", 3_000)})
      next = Chat.record_answer(sent, Map.put(message("ok"), :tokens_in, 1_000))
      assert_in_delta next.chars_per_token, 3.001, 1.0e-9
      assert next.tokens_in == 1_000

      # The next request is estimated with it: no measurement, no change.
      assert sent |> Chat.record_answer(message("ok")) |> Map.get(:chars_per_token) == nil
    end

    test "a prompt the server cut is noticed" do
      cut = Chat.record_answer(ctx(%{context: 65_536}), Map.put(message("ok"), :tokens_in, 32_770))
      assert cut.context_truncated
      whole = Chat.record_answer(ctx(%{context: 65_536}), Map.put(message("ok"), :tokens_in, 30_000))
      refute Map.get(whole, :context_truncated, false)
    end
  end

  describe "summarising earlier turns (P4c)" do
    # 12k tokens of context leave 4_096 for a request: 20 turns of 1k characters are far over 60%.
    defp due(extra \\ %{}), do: ctx(Map.merge(%{system: "S", context: 12_288, messages: long_history(20, 1_000)}, extra))

    test "a short conversation goes from the skill choice straight to thinking" do
      machine = Machine.fetch!(Chat)

      for value <- [:first, :second, :third, :none, :abstain] do
        assert {:ok, %{to: :thinking}} =
                 Engine.handle(machine, :choosing_skill, ctx(%{messages: long_history(2, 10)}), {:decided, value}, %{})
      end
    end

    test "a long one is summarised first, the chosen skill kept" do
      machine = Machine.fetch!(Chat)
      skills = [%{name: "a", description: "A."}, %{name: "b", description: "B."}, %{name: "c", description: "C."}]

      for {value, name} <- [first: "a", second: "b", third: "c", none: nil, abstain: nil] do
        assert {:ok, %{to: :summarising, ctx: summarising}} =
                 Engine.handle(machine, :choosing_skill, due(%{skill_candidates: skills}), {:decided, value}, %{})

        assert get_in(summarising, [:suggested_skill, :name]) == name
      end
    end

    test "the summary is asked without tools and without streaming, for the oldest turns only" do
      [effect] = Chat.ask_summary(due())
      assert %{tools: false, quiet: true} = effect.args
      assert effect.reply == :summarised
      assert [%{role: "system"}, %{role: "user", content: transcript}] = effect.args.messages
      assert transcript =~ "User: request 1\n"
      refute transcript =~ "User: request 20"
    end

    test "the summary stands in for those turns from then on, in the requests and in the turn" do
      machine = Machine.fetch!(Chat)

      assert {:ok, %{to: :thinking, ctx: summarised}} =
               Engine.handle(machine, :summarising, due(), :summarised, message("Goal: x."))

      assert [%{summary: true, content: summary, covers: covers} | kept] = summarised.messages
      assert summary =~ "Goal: x."
      assert covers + length(kept) == 40
      assert List.last(kept) == List.last(long_history(20, 1_000))

      [ask] = Chat.ask_model(summarised)
      assert [%{role: "system"}, %{summary: true} | _] = ask.args.messages
    end

    test "a failed or empty summary leaves the conversation as it was" do
      machine = Machine.fetch!(Chat)

      for failed <- [%{error: :timeout}, message("  ")] do
        assert {:ok, %{to: :thinking, ctx: unchanged}} = Engine.handle(machine, :summarising, due(), :summarised, failed)
        assert unchanged.messages == due().messages
      end
    end

    test "a steer while summarising waits for the model's request" do
      assert {:ok, %{to: :summarising, ctx: steered}} =
               Engine.handle(Machine.fetch!(Chat), :summarising, due(), :steered, %{text: "use psql"})

      assert steered.steers == ["use psql"]
    end
  end

  describe "a review answered with text instead of y or n" do
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

  describe "steering: a line from the user while the turn works" do
    defp sent(ctx), do: ctx |> Chat.ask_model() |> hd() |> then(& &1.args.messages)
    defp steer_message(text), do: %{role: "user", content: "(The user, while you were working:) " <> text}

    defp asked(extra \\ %{}),
      do: ctx(Map.merge(%{turn: [%{role: "system", content: "s"}, %{role: "user", content: "p"}]}, extra))

    test "a steer between model calls goes with the next request, and before its reply in the turn" do
      ctx = Chat.steer(asked(), %{text: "use pytest"})
      assert List.last(sent(ctx)) == steer_message("use pytest")

      answered = Chat.record_answer(ctx, message("Done with pytest."))

      assert Enum.take(answered.turn, -2) == [
               steer_message("use pytest"),
               %{role: "assistant", content: "Done with pytest."}
             ]

      assert Chat.undelivered(answered) == []
    end

    test "a steer while the model is asked waits for its reply, then goes with the next request" do
      ctx = Chat.steer_late(asked(), %{text: "skip the docs"})
      refute steer_message("skip the docs") in sent(ctx)

      queued = Chat.queue_calls(ctx, message("", [call("bash", %{"command" => "ls"})]))
      refute steer_message("skip the docs") in queued.turn
      assert Chat.undelivered(queued) == ["skip the docs"]

      after_tool = Chat.record_result(queued, %{exit_status: 0, output: "a"})
      assert List.last(sent(after_tool)) == steer_message("skip the docs")
    end

    test "steers the turn ends before delivering are handed back" do
      ctx = asked() |> Chat.steer(%{text: "one"}) |> Chat.steer_late(%{text: "two"})
      assert Chat.undelivered(ctx) == ["one", "two"]
      assert Chat.undelivered(Chat.record_answer(ctx, message("ok"))) == ["two"]
    end

    test "the wrap-up request carries pending steers too" do
      ctx = Chat.steer(asked(%{steps: 25}), %{text: "summarise briefly"})
      [effect] = Chat.ask_wrap_up(ctx)
      assert steer_message("summarise briefly") in effect.args.messages
    end

    test "every working state takes a steer without leaving; a finished turn ignores it" do
      machine = Machine.fetch!(Chat)

      for state <- [:thinking, :risk_check, :executing, :ask_human, :verifying, :wrapping_up] do
        assert {:ok, %{to: ^state, entered: [], effects: []} = step} =
                 Engine.handle(machine, state, asked(), :steered, %{text: "t"})

        assert Chat.undelivered(step.ctx) == ["t"], "#{state}"
      end

      assert :ignored = Engine.handle(machine, :answered, asked(), :steered, %{text: "t"})
    end
  end
end
