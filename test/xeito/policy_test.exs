defmodule Xeito.PolicyTest do
  use ExUnit.Case, async: true

  alias Xeito.Budget
  alias Xeito.Decision
  alias Xeito.Decisions.Risk
  alias Xeito.Decisions.Triage
  alias Xeito.Policy
  alias Xeito.Tiers.Queue

  defp all_available(_tier), do: true

  test "defaults keep inputs local and the remote tier off" do
    policy = Policy.for_type(Decision.type!(Triage))
    assert %{remote: :forbidden, locality: :local_only, human: false} = policy

    assert Policy.plan(policy, [:small, :large, :remote], nil, &all_available/1) == [
             :rules,
             :small,
             :large
           ]
  end

  test "remote needs both :allowed and :public, and budget left" do
    type = Decision.type!(Triage)
    open = Policy.for_type(type, policy: [remote: :allowed, locality: :public])
    assert Policy.plan(open, [:remote], nil, &all_available/1) == [:rules, :remote]

    local = Policy.for_type(type, policy: [remote: :allowed])
    assert Policy.plan(local, [:remote], nil, &all_available/1) == [:rules]

    run = "policy-test-#{System.unique_integer([:positive])}"
    Budget.add(run, :usd, 0.75)
    assert Policy.plan(open, [:remote], run, &all_available/1) == [:rules]
  end

  test "OpenRouter is off-box: it shares the remote gate, locality rule and budget" do
    type = Decision.type!(Triage)
    open = Policy.for_type(type, policy: [remote: :allowed, locality: :public])

    assert Policy.plan(open, [:small, :openrouter, :remote], nil, &all_available/1) ==
             [:rules, :small, :openrouter, :remote]

    local = Policy.for_type(type, policy: [remote: :allowed])
    assert Policy.plan(local, [:small, :openrouter], nil, &all_available/1) == [:rules, :small]

    risk = Policy.for_type(Decision.type!(Risk), policy: [remote: :allowed, locality: :public])
    assert Policy.plan(risk, [:openrouter], nil, &all_available/1) == [:rules]
  end

  test "a type-level remote: :forbidden cannot be overridden" do
    policy = Policy.for_type(Decision.type!(Risk), policy: [remote: :allowed, locality: :public])
    assert policy.remote == :forbidden
    assert Policy.plan(policy, [:remote], nil, &all_available/1) == [:rules]
  end

  test "unavailable tiers are dropped and a human can close the ladder" do
    policy = Policy.for_type(Decision.type!(Triage), policy: [human: true])
    assert Policy.plan(policy, [:small, :large], nil, &(&1 == :large)) == [:rules, :large, :human]
  end

  test "the queue admits at most `capacity` concurrent calls per tier" do
    Application.put_env(:xeito, :tier_capacity, %{test_tier: 2})
    on_exit(fn -> Application.delete_env(:xeito, :tier_capacity) end)
    {:ok, counter} = Agent.start_link(fn -> {0, 0} end)

    work = fn ->
      Agent.update(counter, fn {now, peak} -> {now + 1, max(peak, now + 1)} end)
      Process.sleep(30)
      Agent.update(counter, fn {now, peak} -> {now - 1, peak} end)
    end

    1..6
    |> Enum.map(fn _ -> Task.async(fn -> Queue.run(:test_tier, work) end) end)
    |> Task.await_many()

    assert {0, 2} = Agent.get(counter, & &1)
    assert Queue.status(:test_tier) == {0, 0}
  end

  test "by default only configured tiers are available" do
    assert Policy.plan(Policy.for_type(Decision.type!(Triage)), [:no_such_tier]) == [:rules]
  end

  test "off-box spend is allowed below the per-run limit, not at it" do
    open =
      Policy.for_type(Decision.type!(Triage), policy: [remote: :allowed, locality: :public, max_usd_per_run: 0.5])

    run = "policy-usd-#{System.unique_integer([:positive])}"
    assert Policy.remote_allowed?(open, nil)
    Budget.add(run, :usd, 0.25)
    assert Policy.remote_allowed?(open, run)
    Budget.add(run, :usd, 0.25)
    refute Policy.remote_allowed?(open, run)
  end

  test "large-model swaps are allowed below the per-run limit, not at it" do
    policy = Policy.for_type(Decision.type!(Triage), policy: [max_swaps_per_run: 2])
    run = "policy-swaps-#{System.unique_integer([:positive])}"
    assert Policy.swap_allowed?(policy, nil)
    Budget.add(run, :swaps, 1)
    assert Policy.swap_allowed?(policy, run)
    Budget.add(run, :swaps, 1)
    refute Policy.swap_allowed?(policy, run)
  end
end
