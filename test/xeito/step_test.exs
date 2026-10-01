defmodule Xeito.StepTest do
  use Xeito.Case, async: true

  alias Xeito.Decisions.Triage
  alias Xeito.Log
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Run
  alias Xeito.RunSupervisor
  alias Xeito.Session

  @ctx %{cwd: "/tmp", test_cmd: "mix test"}

  defp start(log, debug) do
    runner =
      scripted_runner(
        [%{exit_status: 1, output: "1 failure"}, %{exit_status: 1, output: "1 failure"}],
        fn _ -> :code_bug end
      )

    {:ok, id} =
      RunSupervisor.start_run(FixFailingTest, @ctx,
        run_id: run_id(),
        log: log,
        runner: runner,
        debug: debug
      )

    id
  end

  defp paused_in(id, leaf),
    do: eventually(fn -> Run.whereis(id) && match?(%{leaf: ^leaf, paused: true}, Run.snapshot(id)) end)

  test "step mode holds each result until released; a held decision can be answered by a human" do
    log = start_log!()
    Xeito.Events.subscribe(:all)
    id = start(log, %{step: true, breakpoints: []})

    paused_in(id, :reproduce)

    assert_receive {:xeito, ^id, %{type: "paused", attrs: %{"state" => :reproduce, "kind" => :bash}}}

    assert :ok = Run.step(id)

    # The triage decision (the model said code_bug) is held; a human answers flaky instead.
    paused_in(id, :triage)
    assert {:error, :invalid_value} = Run.step(id, {:decide, :nonsense})
    assert :ok = Run.step(id, {:decide, :flaky})
    paused_in(id, :rerun)
    assert :ok = Run.debug(id, %{step: false})

    [decision] =
      for {_, "decision_made", {:decision_made, _, d}} <- Log.read_run(log, id), do: d

    assert %{value: :flaky, actor: :human, confidence: 1.0} = decision
    assert [%{replaced: %{value: :code_bug}}] = decision.evidence
    assert {:error, :not_paused} = Run.step(id)
  end

  test "a decision breakpoint pauses only at that decision" do
    log = start_log!()
    id = start(log, %{step: false, breakpoints: [{:decision, Triage}]})

    paused_in(id, :triage)
    assert :ok = Run.step(id)
    eventually(fn -> Run.whereis(id) && Run.snapshot(id).leaf == :planning end)
    refute Run.snapshot(id).paused
    Run.send_event(id, :give_up)
  end

  test "breakpoint specs parse without creating atoms from input" do
    assert {:ok, {:state, :triage}} = Session.parse_breakpoint("state:triage")
    assert {:ok, {:decision, Triage}} = Session.parse_breakpoint("decision:triage")
    assert {:ok, {:confidence_below, 0.6}} = Session.parse_breakpoint("conf<0.6")

    assert :error =
             Session.parse_breakpoint("state:no_such_state_#{System.unique_integer([:positive])}")

    assert :error = Session.parse_breakpoint("decision:Nope")
    assert :error = Session.parse_breakpoint("whatever")
  end
end
