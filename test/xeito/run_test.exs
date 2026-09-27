defmodule Xeito.RunTest do
  use Xeito.Case, async: true

  alias Xeito.{Log, Run, RunSupervisor}
  alias Xeito.Log.Event
  alias Xeito.Machines.{FixFailingTest, RunTests}
  alias Xeito.TestMachines.Sleepy

  @ctx %{cwd: "/tmp", test_cmd: "mix test"}

  defp start(machine, runner, log, input \\ @ctx) do
    {:ok, id} =
      RunSupervisor.start_run(machine, input, run_id: run_id(), log: log, runner: runner)

    id
  end

  defp wait_for_leaf(id, expected),
    do: eventually(fn -> Run.whereis(id) && Run.snapshot(id).leaf == expected end)

  test "run_tests finishes :done when the command passes" do
    log = start_log!()
    id = start(RunTests, scripted_runner([%{exit_status: 0, output: "ok"}]), log)

    await_exit(id)
    assert {:ok, %{status: :done, state: :done}} = Run.result(log, id)
  end

  test "fix_failing_test: reproduce → triage → plan/edit/verify → done" do
    log = start_log!()

    runner =
      scripted_runner(
        [%{exit_status: 1, output: "1 failure"}, %{exit_status: 0, output: "ok"}],
        fn _ -> :code_bug end
      )

    id = start(FixFailingTest, runner, log)

    wait_for_leaf(id, :planning)
    assert {:ok, :editing} = Run.send_event(id, :planned, %{plan: "fix rounding"}, :human)
    assert :ignored = Run.send_event(id, :planned)
    assert {:ok, :verifying} = Run.send_event(id, :edited)

    await_exit(id)
    assert {:ok, %{status: :done, state: :done}} = Run.result(log, id)

    transitions =
      for {_, "transition", {:transition, from, to, _event, _actor}} <- Log.read_run(log, id),
          do: {from, to}

    assert transitions == [
             reproduce: :triage,
             triage: :planning,
             planning: :editing,
             editing: :verifying,
             verifying: :done
           ]
  end

  test "failed verification loops back to planning until attempts run out" do
    log = start_log!()
    failing = %{exit_status: 1, output: "still failing"}
    runner = scripted_runner(List.duplicate(failing, 4), fn _ -> :test_bug end)
    id = start(FixFailingTest, runner, log, Map.put(@ctx, :max_attempts, 2))

    wait_for_leaf(id, :planning)
    Run.send_event(id, :planned)
    Run.send_event(id, :edited)
    wait_for_leaf(id, :planning)
    assert Run.snapshot(id).ctx.attempts == 1
    Run.send_event(id, :planned)
    Run.send_event(id, :edited)

    await_exit(id)
    assert {:ok, %{status: :failed, state: :failed, ctx: %{attempts: 1}}} = Run.result(log, id)
  end

  test "an unhandled timeout fails the run" do
    log = start_log!()
    id = start(Sleepy, :none, log, %{})

    await_exit(id)
    assert {:ok, %{status: :failed, state: :failed}} = Run.result(log, id)

    assert Enum.any?(
             Log.read_run(log, id),
             &match?({_, "transition", {:transition, :waiting, :failed, :timeout, _}}, &1)
           )
  end

  test "a killed run is restarted by its supervisor and resumes from the log" do
    log = start_log!()

    runner =
      scripted_runner(
        [%{exit_status: 1, output: "fail"}, %{exit_status: 0, output: "ok"}],
        fn _ -> :code_bug end
      )

    id = start(FixFailingTest, runner, log)

    wait_for_leaf(id, :planning)
    {:ok, :editing} = Run.send_event(id, :planned, %{plan: "p"})
    before = Run.snapshot(id)
    old_pid = Run.whereis(id)

    Process.exit(old_pid, :kill)
    eventually(fn -> (pid = Run.whereis(id)) && pid != old_pid end)

    assert Run.snapshot(id) == before

    assert Enum.any?(
             Log.read_run(log, id),
             &match?({_, "run_recovered", {:run_recovered, :editing}}, &1)
           )

    {:ok, :verifying} = Run.send_event(id, :edited)
    await_exit(id)
    assert {:ok, %{status: :done}} = Run.result(log, id)
  end

  test "an effect in flight during a crash is re-dispatched after recovery" do
    log = start_log!()
    test_pid = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    fun = fn %Xeito.Effect{kind: :bash} = effect ->
      n = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
      send(test_pid, {:effect_called, n, effect.id})
      # The first execution never finishes, as if the run crashed mid-effect.
      if n == 1, do: Process.sleep(:infinity), else: %{exit_status: 0, output: "ok"}
    end

    id = start(RunTests, {Xeito.Effects.Fake, fun: fun}, log)
    assert_receive {:effect_called, 1, effect_id}

    old_pid = Run.whereis(id)
    Process.exit(old_pid, :kill)

    assert_receive {:effect_called, 2, ^effect_id}, 2_000
    await_exit(id)
    assert {:ok, %{status: :done}} = Run.result(log, id)
  end

  test "recovery refuses a run whose machine version changed" do
    log = start_log!()
    id = run_id()

    Log.append(log, id, [
      Event.new("run_started", {:run_started, RunTests, "0.0.0-old", @ctx}, %{
        "machine" => "run_tests"
      })
    ])

    assert {:error, {:recovery_failed, {:version_mismatch, _}}} =
             RunSupervisor.resume_run(RunTests, id, log: log, runner: :none)

    assert Run.whereis(id) == nil
  end
end
