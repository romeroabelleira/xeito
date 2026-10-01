defmodule Xeito.BudgetTest do
  # The sweep reaches every entry in the shared table, so not async.
  use ExUnit.Case, async: false

  alias Xeito.Budget

  test "amounts add up per run and key: whole counts and fractions (spend); delete clears a run" do
    run = "budget-add-#{System.unique_integer([:positive])}"
    assert Budget.get(run, :usd) == 0
    assert Budget.add(run, :usd, 0.25) == 0.25
    assert Budget.add(run, :usd, 0.5) == 0.75
    assert Budget.add(run, :swaps, 1) == 1
    assert Budget.add(run, :swaps, 2) == 3
    assert Budget.get(run, :usd) == 0.75

    assert Budget.delete(run) == :ok
    assert {Budget.get(run, :usd), Budget.get(run, :swaps)} == {0, 0}
  end

  test "the sweep drops entries whose owner is neither a live run nor a live session" do
    n = System.unique_integer([:positive])
    {dead, run, session} = {"budget-dead-#{n}", "budget-run-#{n}", "budget-ses-#{n}"}
    # The test process stands in for a live run and a live session.
    {:ok, _} = Registry.register(Xeito.RunRegistry, run, nil)
    {:ok, _} = Registry.register(Xeito.SessionRegistry, session, nil)
    for owner <- [dead, run, session], do: Budget.add(owner, :swaps, 1)

    assert Budget.sweep() >= 1
    assert {Budget.get(dead, :swaps), Budget.get(run, :swaps), Budget.get(session, :swaps)} == {0, 1, 1}
  end
end
