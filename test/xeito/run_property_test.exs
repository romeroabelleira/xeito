defmodule Xeito.RunPropertyTest do
  @moduledoc """
  P1 exit criterion: for random event sequences, the log alone reproduces the final state.
  """

  use Xeito.Case, async: true
  use ExUnitProperties

  alias Xeito.{Log, Run, RunSupervisor}
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Run.Recovery

  defp event do
    one_of([
      tuple({constant(:ran), map(member_of([0, 1]), &%{exit_status: &1, output: ""})}),
      tuple(
        {member_of(
           Enum.map([:flaky, :code_bug, :test_bug, :env_problem, :abstain], &{:decided, &1})
         ), constant(%{})}
      ),
      tuple(
        {member_of([:planned, :edited, :answered, :give_up, :abort, :timeout, :bogus]),
         constant(%{})}
      )
    ])
  end

  property "rebuilding from the log yields the live run's state and context" do
    log = start_log!()

    check all(events <- list_of(event(), max_length: 40), max_runs: 60) do
      {:ok, id} =
        RunSupervisor.start_run(FixFailingTest, %{cwd: "/tmp", max_attempts: 3},
          run_id: run_id(),
          log: log,
          runner: :none
        )

      live = drive(id, events)
      {:ok, rebuilt} = Recovery.rebuild(FixFailingTest, Log.read_run(log, id))

      case live do
        {:running, snapshot} ->
          assert {rebuilt.leaf, rebuilt.ctx} == {snapshot.leaf, snapshot.ctx}
          assert rebuilt.finished == false
          :gen_statem.stop(Run.whereis(id))

        :finished ->
          await_exit(id)
          {:ok, result} = Run.result(log, id)
          assert {rebuilt.leaf, rebuilt.ctx} == {result.state, result.ctx}
      end
    end
  end

  # Sends events until the run finishes; returns the final snapshot or :finished.
  defp drive(id, events) do
    Enum.reduce_while(events, nil, fn {name, data}, _ ->
      case Run.send_event(id, name, data, :code) do
        {:ok, leaf} when leaf in [:done, :failed] -> {:halt, :finished}
        _ -> {:cont, nil}
      end
    end)
    |> case do
      :finished -> :finished
      nil -> {:running, Run.snapshot(id)}
    end
  end
end
