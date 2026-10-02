defmodule Mix.Tasks.Xeito.CandidatesTest do
  # Uses the shared workspace-log supervisor and Mix's shell.
  use Xeito.Case, async: false

  alias Mix.Tasks.Xeito.Candidates
  alias Xeito.Decision
  alias Xeito.Decisions.Intent
  alias Xeito.Effect
  alias Xeito.Log
  alias Xeito.Log.Event
  alias Xeito.Machines.Chat
  alias Xeito.Machines.RunTests

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-cand-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    %{ws: ws, log: Log.for_workspace(ws)}
  end

  # A finished turn: its intent run (unless nil) and its run of `machine` with `effects`.
  defp turn(log, run, prompt, intent, effects, machine \\ Chat) do
    # As the log has it: an escalation run whose final context holds the committed decision.
    if intent do
      decision = %Decision{type: Intent, value: intent, confidence: 1.0, actor: :large}

      {:ok, _} =
        Log.append(log, run <> "/intent", [
          Event.new("run_started", {:run_started, Xeito.Machines.Escalation, "1.1.0", %{}}),
          Event.new("run_finished", {:run_finished, :done, :committed, %{decision: decision}})
        ])
    end

    started = Event.new("run_started", {:run_started, machine, "1", %{prompt: prompt, request: prompt}})
    requested = Enum.map(effects, &Event.new("effect_requested", {:effect_requested, &1}))
    finished = Event.new("run_finished", {:run_finished, :done, :answered, %{tokens_in: 3_000, tokens_out: 500}})
    {:ok, _} = Log.append(log, run, [started | requested] ++ [finished])
  end

  defp test_turn,
    do: [
      Effect.chat([]),
      Effect.read("lib/a.ex"),
      Effect.chat([]),
      Effect.edit("test/a_test.exs", "a", "b"),
      Effect.bash("mix format", reply: :verified),
      Effect.chat([]),
      Effect.chat([])
    ]

  defp explain_turn, do: [Effect.chat([]), Effect.read("lib/a.ex"), Effect.chat([]), Effect.chat([]), Effect.chat([])]

  defp seed(log) do
    for {object, n} <- Enum.with_index(~w(Pricing Cart Order User Invoice), 1),
        do: turn(log, "ses-a/t#{n}", "add a test for #{object}.total/1", :edit, test_turn())

    turn(log, "ses-b/t1", "explain the error in the log", :explain, explain_turn())
    turn(log, "ses-b/t2", "explain this error", :explain, explain_turn())
    # Not free chat: a continuation (no intent run), a /run turn, small talk.
    turn(log, "ses-b/t3", "go ahead", nil, test_turn())
    turn(log, "ses-b/t4", "/run mix test", :run, [Effect.bash("mix test")], RunTests)
    turn(log, "ses-b/t5", "thanks", :other, [Effect.chat([])])
  end

  defp run(ws, args) do
    Candidates.run(args ++ ["--cwd", ws])
    output()
  end

  defp output(acc \\ "") do
    receive do
      {:mix_shell, :info, [line]} -> output(acc <> line <> "\n")
    after
      0 -> acc
    end
  end

  test "frequent free-chat requests are reported as candidates, with their evidence", %{ws: ws, log: log} do
    seed(log)
    out = run(ws, [])

    assert out =~ "7 free-chat turns in 2 groups of similar prompts; 1 candidate (at least 5 runs)"
    assert out =~ "machine · 5 runs · intent edit · 100% answered · 4.0 model turns · 3500 tokens"
    assert out =~ "because 100% of runs follow one variant, which ends in a check"
    assert out =~ "variant (5 of 5): read › edit › check"
    assert out =~ ~s(e.g. "add a test for Pricing.total/1", "add a test for Cart.total/1", "add a test for Order.total/1")
    refute out =~ "explain"
  end

  test "--all also lists the groups that are not candidates, and why; --min-runs lowers the bar", %{ws: ws, log: log} do
    seed(log)
    all = run(ws, ["--all"])
    assert all =~ "none · 2 runs · intent explain"
    assert all =~ "because 2 runs; candidates need 5"

    assert run(ws, ["--min-runs", "2"]) =~ "skill · 2 runs · intent explain"

    turn(log, "ses-c/t1", "rename the module", :edit, test_turn())
    assert run(ws, ["--all"]) =~ "none · 1 run · intent edit"
  end

  test "a log without free-chat turns says so; a workspace without a log is an error", %{ws: ws, log: log} do
    turn(log, "ses-c/t1", "/run mix test", :run, [Effect.bash("mix test")], RunTests)
    assert run(ws, []) =~ "no free-chat turns in this log yet"
    assert_raise Mix.Error, ~r/^no log at /, fn -> run(Path.join(ws, "nowhere"), []) end
  end
end
