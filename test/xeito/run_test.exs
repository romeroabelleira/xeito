defmodule Xeito.RunTest do
  use Xeito.Case, async: true

  alias Xeito.Effects.Fake
  alias Xeito.Log
  alias Xeito.Log.Event
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Machines.RunTests
  alias Xeito.Run
  alias Xeito.RunSupervisor
  alias Xeito.TestMachines.Sleepy

  @ctx %{cwd: "/tmp", test_cmd: "mix test"}

  defp start(machine, runner, log, input \\ @ctx) do
    {:ok, id} =
      RunSupervisor.start_run(machine, input, run_id: run_id(), log: log, runner: runner)

    id
  end

  defp wait_for_leaf(id, expected), do: eventually(fn -> Run.whereis(id) && Run.snapshot(id).leaf == expected end)

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

    id = start(RunTests, {Fake, fun: fun}, log)
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

  test "a decide effect is answered by the decider and logged as decision_made" do
    log = start_log!()
    dir = Path.join(System.tmp_dir!(), "xeito-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    # The failure output matches Triage's missing-environment rule, so no model tier is needed.
    input = %{cwd: dir, test_cmd: "echo '** (Mix) The task x could not be found'; exit 1"}
    id = start(FixFailingTest, {Xeito.Effects.Local, decider: [deciders: []]}, log, input)

    wait_for_leaf(id, :ask_human)

    assert [{:decision_made, _effect, decision}] =
             for({_, "decision_made", term} <- Log.read_run(log, id), do: term)

    assert %{value: :env_problem, actor: :rule, confidence: 1.0} = decision

    assert [["env_problem", "rule", "1.0"]] =
             Log.query(log, "SELECT value, actor, confidence FROM event_decision_made")

    assert Enum.any?(
             Log.read_run(log, id),
             &match?(
               {_, "transition", {:transition, :triage, :ask_human, {:decided, :env_problem}, :rule}},
               &1
             )
           )

    Run.send_event(id, :abort)
  end

  describe "halt/2" do
    # An effect that never finishes: it tells the test which process runs it, then waits.
    defp hanging(test) do
      {Fake,
       fun: fn _effect ->
         send(test, {:effect_task, self()})
         Process.sleep(:infinity)
       end}
    end

    test "stops a run where it is: its effect is killed and it is logged as halted, for good" do
      log = start_log!()
      id = start(RunTests, hanging(self()), log)
      assert_receive {:effect_task, task}
      ref = Process.monitor(task)

      assert Run.halt(id) == :ok
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      await_exit(id)
      assert {:ok, %{status: :halted, state: :running}} = Run.result(log, id)

      # Finished: recovery does not bring it back, and the log replays cleanly.
      assert {:ok, %{finished: true, desync: nil}} = Xeito.Run.Recovery.rebuild(RunTests, Log.read_run(log, id))
    end

    test "halts the runs under it too: delegated and escalation runs" do
      log = start_log!()
      parent = run_id()

      for id <- [parent, parent <> "/e1/run", parent <> "/e2/esc"] do
        {:ok, ^id} = RunSupervisor.start_run(RunTests, @ctx, run_id: id, log: log, runner: hanging(self()))
        assert_receive {:effect_task, _}
      end

      unrelated = start(RunTests, hanging(self()), log)
      assert_receive {:effect_task, _}

      assert Run.halt(parent) == :ok

      for id <- [parent, parent <> "/e1/run", parent <> "/e2/esc"] do
        await_exit(id)
        assert {:ok, %{status: :halted}} = Run.result(log, id)
      end

      assert Run.whereis(unrelated)
      assert Run.halt(unrelated) == :ok
    end

    test "a paused run halts too" do
      log = start_log!()

      {:ok, id} =
        RunSupervisor.start_run(RunTests, @ctx,
          run_id: run_id(),
          log: log,
          runner: scripted_runner([%{exit_status: 0, output: "ok"}]),
          debug: %{step: true, breakpoints: []}
        )

      eventually(fn -> Run.snapshot(id).paused end)
      assert Run.halt(id) == :ok
      await_exit(id)
      assert {:ok, %{status: :halted, state: :running}} = Run.result(log, id)
    end

    test "a run that is not running cannot be halted" do
      assert Run.halt("no-such-run") == {:error, :not_running}
    end
  end
end
