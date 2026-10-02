defmodule Xeito.PromotionTest do
  use ExUnit.Case, async: true

  alias Xeito.Effect
  alias Xeito.Machines.Chat
  alias Xeito.Promotion

  # A chat turn's log entries: started with the prompt, the effects in order, finished.
  defp entries(prompt, effects, finish \\ {:done, :answered, %{tokens_in: 900, tokens_out: 100}}, extra \\ []) do
    {status, leaf, ctx} = finish
    started = {1, "run_started", {:run_started, Chat, "0.7.0", %{prompt: prompt, request: prompt}}}

    requested =
      for {effect, i} <- Enum.with_index(effects, 2), do: {i, "effect_requested", {:effect_requested, effect}}

    finished = {100, "run_finished", {:run_finished, status, leaf, ctx}}
    [started | requested] ++ extra ++ [finished]
  end

  defp chat, do: Effect.chat([])

  describe "trace/2: what a free-chat turn did" do
    test "the prompt, the steps (model calls aside), the outcome and the cost" do
      effects = [
        chat(),
        Effect.read("lib/a.ex"),
        Effect.read("lib/b.ex"),
        chat(),
        Effect.edit("lib/a.ex", "x", "y"),
        Effect.bash("mix format", reply: :verified),
        chat(),
        Effect.bash("mix test test/a_test.exs"),
        Effect.bash("git diff --stat"),
        Effect.bash("ls -la"),
        Effect.write("notes.md", "n")
      ]

      assert %{
               run: "ses-1/t1",
               prompt: "add a test",
               intent: :edit,
               steps: ["read", "read", "edit", "check", "bash:mix test", "bash:git diff", "bash:ls", "write"],
               outcome: :answered,
               turns: 3,
               tokens: 1000
             } = Promotion.trace("ses-1/t1", entries("add a test", effects), :edit)
    end

    test "a turn that failed, stopped at its limit, was halted, or had a review answered otherwise" do
      outcome = fn finish, extra -> Promotion.trace("r", entries("p", [], finish, extra), :edit).outcome end
      human = fn name -> [{50, "event_received", {:event, name, %{}, :human}}] end

      assert outcome.({:failed, :failed, %{}}, []) == :failed
      assert outcome.({:done, :answered, %{stopped: true}}, []) == :stopped
      assert outcome.({:halted, :executing, %{}}, []) == :halted
      assert outcome.({:done, :answered, %{}}, human.(:denied)) == :overruled
      assert outcome.({:done, :answered, %{}}, human.(:instructed)) == :overruled
      assert outcome.({:done, :answered, %{}}, human.(:approved)) == :answered
    end

    test "the prompt is the request, else the chat input's prompt; an empty command is a step too" do
      started = fn input ->
        [
          {1, "run_started", {:run_started, Chat, "0.7.0", input}},
          {9, "run_finished", {:run_finished, :done, :answered, %{}}}
        ]
      end

      assert Promotion.trace("r", started.(%{prompt: "only the prompt"}), :edit).prompt == "only the prompt"
      assert Promotion.trace("r", started.(%{}), :edit).prompt == ""
      assert Promotion.trace("r", entries("p", [Effect.bash("")]), :edit).steps == ["bash:"]
    end

    test "only a finished chat run is a trace" do
      other = [{1, "run_started", {:run_started, Xeito.Machines.RunTests, "0.1.0", %{}}}]
      assert Promotion.trace("r", other, :run) == nil
      assert Promotion.trace("r", Enum.drop(entries("p", []), -1), :edit) == nil
    end
  end

  test "variant/1: the steps with repeats collapsed" do
    assert Promotion.variant(["read", "read", "edit", "check", "edit", "edit", "check"]) ==
             ["read", "edit", "check", "edit", "check"]
  end

  describe "prompts" do
    test "words/1: lowercase words, without filler, code names or plurals" do
      assert Promotion.words("Please add tests for Pricing.gross/1 in lib/pricing.ex") == MapSet.new(["add", "test"])
      assert Promotion.words("Rename the module MyApp.Cart and fix_callers") == MapSet.new(["rename", "module"])
    end

    test "plurals lose their s, but not short words or words ending in ss" do
      assert Promotion.words("bugs bus class") == MapSet.new(["bug", "bus", "class"])
    end

    test "similarity/2: the share of words two prompts have in common" do
      assert Promotion.similarity("add a test for A.b/1", "add tests for C.d") == 1.0
      assert Promotion.similarity("add a test", "explain the error") == 0.0
      assert Promotion.similarity("add a test", "add a module") == 1 / 3
      assert Promotion.similarity("", "") == 0.0
    end
  end

  describe "clusters/2" do
    defp t(run, prompt, intent \\ :edit), do: %{run: run, prompt: prompt, intent: intent}

    test "prompts sharing most of their words, with the same intent, go together, in log order" do
      traces = [
        t("s/t1", "add a test for A.b"),
        t("s/t2", "explain the error"),
        t("s/t3", "add tests for C.d"),
        t("s/t4", "add a test for X", :question),
        t("s/t5", "explain this error please")
      ]

      assert traces |> Promotion.clusters(0.5) |> Enum.map(fn c -> Enum.map(c, & &1.run) end) ==
               [["s/t1", "s/t3"], ["s/t2", "s/t5"], ["s/t4"]]
    end

    test "a prompt exactly as similar as the threshold joins" do
      traces = [t("s/t1", "add a test"), t("s/t2", "add a test module fix")]
      assert length(Promotion.clusters(traces, 0.5)) == 1
    end
  end

  describe "summary/1 and target/2" do
    defp run(variant, outcome \\ :answered, turns \\ 6, tokens \\ 20_000),
      do: %{
        run: "r",
        prompt: "add a test for X",
        intent: :edit,
        steps: variant,
        outcome: outcome,
        turns: turns,
        tokens: tokens
      }

    @machine_like ["read", "edit", "check", "bash:mix test"]

    test "a cluster's size, success, mean cost, and its variants with the dominant one first" do
      cluster = List.duplicate(run(@machine_like), 3) ++ [run(["read", "edit", "check"], :failed, 10, 40_000)]

      assert %{
               intent: :edit,
               runs: 4,
               success: 0.75,
               turns: 7.0,
               tokens: 25_000,
               variants: [{@machine_like, 3}, {["read", "edit", "check"], 1}],
               dominant: 0.75,
               examples: ["add a test for X"]
             } = Promotion.summary(cluster)
    end

    defp target(cluster, opts \\ []), do: cluster |> Promotion.summary() |> Promotion.target(opts) |> elem(0)

    test "frequent, successful and following one variant to a checkable end: a machine" do
      assert target(List.duplicate(run(@machine_like), 5)) == :machine
      assert target(List.duplicate(run(["read", "edit", "check"]), 5)) == :machine
    end

    test "a checkable end is the quick check or a project's test command" do
      for test_step <- ~w(check bash:pytest) ++ Enum.map(~w(mix npm pnpm yarn cargo go make), &"bash:#{&1} test"),
          do: assert(target(List.duplicate(run(["edit", test_step]), 5)) == :machine, test_step)
    end

    test "frequent and successful, but without a dominant variant or a checkable end: a skill" do
      mixed = for v <- [["read"], ["read", "edit"], ["bash:grep", "edit"], ["read", "bash:ls"], ["edit"]], do: run(v)

      assert {:skill, "no variant dominates (20% at most): guidance, not fixed steps"} =
               Promotion.target(Promotion.summary(mixed), [])

      assert {:skill, "one variant dominates, but it ends without a check"} =
               Promotion.target(Promotion.summary(List.duplicate(run(["read", "edit"]), 5)), [])
    end

    test "the thresholds are inclusive: half answered, three turns, a variant in 70% of runs" do
      half = List.duplicate(run(@machine_like), 2) ++ List.duplicate(run(@machine_like, :failed), 2)
      assert target(half, min_runs: 4) == :machine
      assert target(List.duplicate(run(@machine_like, :answered, 3), 5)) == :machine

      seventy = List.duplicate(run(@machine_like), 7) ++ List.duplicate(run(["read"]), 3)
      assert target(seventy) == :machine
      sixty = List.duplicate(run(@machine_like), 6) ++ List.duplicate(run(["read"]), 4)
      assert target(sixty) == :skill

      unchecked = List.duplicate(run(["read", "edit"]), 7) ++ List.duplicate(run(["read"]), 3)
      assert {:skill, "one variant dominates" <> _} = Promotion.target(Promotion.summary(unchecked), [])
    end

    test "too few, cheap already, or mostly not answered: none, with the reason" do
      assert {:none, "1 run; candidates need 5"} = Promotion.target(Promotion.summary([run(@machine_like)]), [])

      assert {:none, "4 runs; candidates need 5"} =
               Promotion.target(Promotion.summary(List.duplicate(run(@machine_like), 4)), [])

      assert target(List.duplicate(run(@machine_like), 4), min_runs: 4) == :machine
      assert target(List.duplicate(run(@machine_like, :answered, 2), 5)) == :none
      assert target(List.duplicate(run(@machine_like, :failed), 5)) == :none

      assert {:none, "answered in 0% of runs: a bug report, not a candidate"} =
               Promotion.target(Promotion.summary(List.duplicate(run(@machine_like, :halted), 5)), [])
    end
  end
end
