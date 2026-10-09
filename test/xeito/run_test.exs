defmodule Xeito.RunTest do
  use Xeito.Case, async: true

  alias Xeito.Decisions.Triage
  alias Xeito.Effects.Fake
  alias Xeito.Effects.Local
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

  test "an internal transition is logged, and the run stays where it was" do
    log = start_log!()
    id = start(Xeito.TestMachines.Counter, :none, log, %{})

    assert {:ok, :idle} = Run.send_event(id, :note)
    assert {:ok, :idle} = Run.send_event(id, :note)
    assert %{leaf: :idle, ctx: %{count: 2}} = Run.snapshot(id)

    assert [["idle", "idle", "note"], ["idle", "idle", "note"]] =
             Log.query(log, "SELECT from_state, to_state, event_name FROM event_transition WHERE event_name = 'note'")
  end

  test "an internal transition keeps the effect in flight: its result still arrives" do
    log = start_log!()
    id = start(Xeito.TestMachines.Patient, {Local, []}, log, %{cwd: System.tmp_dir!()})

    assert {:ok, :working} = Run.send_event(id, :note)
    await_exit(id)
    assert {:ok, %{status: :done, state: :done, ctx: %{notes: 1}}} = Run.result(log, id)
  end

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
    id = start(FixFailingTest, {Local, decider: [deciders: []]}, log, input)

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

    test "a run whose log is gone is not restarted, so it cannot take other runs down" do
      sup = start_supervised!({RunSupervisor, name: :"runs-#{System.unique_integer([:positive])}"}, id: make_ref())
      path = Path.join(System.tmp_dir!(), "xeito-gone-#{System.unique_integer([:positive])}/log.sqlite")
      on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
      gone = start_supervised!({Log, path: path}, id: :gone)
      other_log = start_log!()

      started = fn log ->
        {:ok, id} =
          RunSupervisor.start_run(RunTests, @ctx, run_id: run_id(), log: log, runner: hanging(self()), supervisor: sup)

        id
      end

      doomed = for _ <- 1..2, do: started.(gone)
      other = started.(other_log)
      wait_for_leaf(other, :running)

      stop_supervised!(:gone)
      ref = Process.monitor(sup)
      for id <- doomed, do: Process.exit(Run.whereis(id), :crashed)

      # Restarted runs that cannot read their log would crash again at once, until the
      # supervisor gives up on all its runs.
      refute_receive {:DOWN, ^ref, :process, _, _}, 500
      assert Enum.all?(doomed, &(Run.whereis(&1) == nil))
      assert Run.whereis(other)
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

  describe "held results in step mode" do
    defmodule TwoAtOnce do
      @moduledoc "Requests two commands on entry; the first result moves on, the second arrives late."
      use Xeito.Machine, version: "1.0.0"

      initial :start

      state :start, entry: :both, timeout: 50 do
        on :ran, to: :next
      end

      state :next, timeout: 60_000 do
        on :go, to: :done
      end

      final :done
      final :failed

      def both(_ctx), do: [Xeito.Effect.bash("a"), Xeito.Effect.bash("b")]
    end

    test "while a result is held, later results wait and the state's timeout is ignored; a stale one is dropped" do
      log = start_log!()
      runner = {Fake, fun: fn _ -> %{exit_status: 0, output: ""} end}

      {:ok, id} =
        RunSupervisor.start_run(TwoAtOnce, %{},
          run_id: run_id(),
          log: log,
          runner: runner,
          debug: %{step: true, breakpoints: []}
        )

      eventually(fn -> Run.snapshot(id).paused end)
      # Longer than the state's 50 ms timeout: a held run does not time out.
      Process.sleep(120)
      assert %{leaf: :start, paused: true} = Run.snapshot(id)

      assert :ok = Run.step(id)
      # The second result belonged to the state the run has left: dropped, nothing held.
      eventually(fn -> Run.snapshot(id).leaf == :next and not Run.snapshot(id).paused end)
      assert {:ok, :done} = Run.send_event(id, :go, %{}, :human)
    end
  end

  describe "breakpoints on decisions" do
    defmodule Deciding do
      @moduledoc "Runs a command, then asks for a Triage decision."
      use Xeito.Machine, version: "1.0.0"

      initial :run

      state :run, entry: :run_cmd do
        on :ran, to: :triage
      end

      state :triage do
        decide(Triage)
        on {:decided, :flaky}, to: :done
        on {:decided, :code_bug}, to: :done
        on {:decided, :test_bug}, to: :done
        on {:decided, :env_problem}, to: :done
        on {:decided, :abstain}, to: :done
      end

      final :done
      final :failed

      def run_cmd(_ctx), do: [Xeito.Effect.bash("x")]
    end

    defp decided(confidence) do
      {Fake,
       fun: fn
         %Xeito.Effect{kind: :bash} ->
           %{exit_status: 0, output: ""}

         %Xeito.Effect{kind: :decide} ->
           # As the real runner reports it (`Xeito.Effects.Local`): the decision as a map.
           decision = %Xeito.Decision{
             type: Triage,
             value: :flaky,
             confidence: confidence,
             actor: :local_decision,
             model: "m"
           }

           %{value: :flaky, decision: Xeito.Decision.to_map(decision)}
       end}
    end

    defp start_with(breakpoints, runner, log \\ start_log!()) do
      {:ok, id} =
        RunSupervisor.start_run(Deciding, %{},
          run_id: run_id(),
          log: log,
          runner: runner,
          debug: %{step: false, breakpoints: breakpoints}
        )

      id
    end

    test "a confidence breakpoint pauses on a decision below it, not above, and not on other effects" do
      low = start_with([{:confidence_below, 0.6}], decided(0.4))
      eventually(fn -> Run.whereis(low) && Run.snapshot(low).paused end)
      assert Run.snapshot(low).leaf == :triage

      log = start_log!()
      high = start_with([{:confidence_below, 0.6}], decided(0.9), log)
      await_exit(high)
      assert {:ok, %{status: :done}} = Run.result(log, high)
    end

    test "a decision breakpoint does not pause on a command's result" do
      log = start_log!()
      id = start_with([{:decision, Xeito.Decisions.Risk}], decided(0.9), log)
      await_exit(id)
      assert {:ok, %{status: :done}} = Run.result(log, id)
    end
  end

  test "debug settings change a live run that holds nothing" do
    log = start_log!()
    id = start(RunTests, {Fake, fun: fn _ -> Process.sleep(:infinity) end}, log)
    assert Run.debug(id, %{step: true}) == :ok
    refute Run.snapshot(id).paused
    assert Run.halt(id) == :ok
  end
end
