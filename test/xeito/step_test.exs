defmodule Xeito.StepTest do
  use Xeito.Case, async: true

  alias Xeito.Decisions.Triage
  alias Xeito.Log
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Run
  alias Xeito.RunSupervisor

  @moduletag :tmp_dir

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

  test "step mode holds each result until released; a held decision can be answered by a human", ctx do
    log = start_log!(ctx)
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

    [decision] =
      for {_, "decision_made", {:decision_made, _, d}} <- Log.read_run(log, id), do: d

    assert %{value: :flaky, actor: :human, confidence: 1.0} = decision
    assert [%{replaced: %{value: :code_bug}}] = decision.evidence

    assert :ok = Run.debug(id, %{step: false})
    assert {:error, :not_paused} = Run.step(id)
  end

  test "a decision breakpoint pauses only at that decision", ctx do
    log = start_log!(ctx)
    id = start(log, %{step: false, breakpoints: [{:decision, Triage}]})

    paused_in(id, :triage)
    assert :ok = Run.step(id)
    eventually(fn -> Run.whereis(id) && Run.snapshot(id).leaf == :planning end)
    refute Run.snapshot(id).paused
    Run.send_event(id, :give_up)
  end

  test "step mode pauses before each of a script's inner results, then before the script's own", ctx do
    log = start_log!(ctx)
    Xeito.Events.subscribe(:all)
    test = self()

    fun = fn
      %Xeito.Effect{kind: :script, id: id} ->
        [run, _] = String.split(id, "/e", parts: 2)
        %{ok: true, content: "A"} = Run.child(run, id, Xeito.Effect.read("a.ex", cwd: "/w"))
        %{value: 7} = Run.child(run, id, Xeito.Effect.now())
        send(test, :script_done)
        %{ok: true, content: "done"}

      %Xeito.Effect{kind: :read} ->
        %{ok: true, content: "A"}

      %Xeito.Effect{kind: :now} ->
        %{value: 7}
    end

    {:ok, id} =
      RunSupervisor.start_run(Xeito.TestMachines.Scripted, %{cwd: "/w"},
        run_id: run_id(),
        log: log,
        runner: {Xeito.Effects.Fake, fun: fun},
        debug: %{step: true, breakpoints: []}
      )

    paused_in(id, :running)
    assert_receive {:xeito, ^id, %{type: "paused", attrs: %{"state" => :running, "kind" => :read}}}
    refute_received :script_done
    assert :ok = Run.step(id)

    paused_in(id, :running)
    assert_receive {:xeito, ^id, %{type: "paused", attrs: %{"kind" => :now}}}
    assert :ok = Run.step(id)

    assert_receive :script_done, 2_000
    paused_in(id, :running)
    assert_receive {:xeito, ^id, %{type: "paused", attrs: %{"kind" => :script}}}
    assert :ok = Run.step(id)

    await_exit(id)
    assert {:ok, %{status: :done, ctx: %{output: "done"}}} = Run.result(log, id)
  end
end
