defmodule Xeito.Machines.Escalation do
  @moduledoc """
  Delegation as a state machine: one run per decision request, walking the tiers of its plan
  (`docs/architecture/04-delegation.md`).

      deciding ─┬─ rules
                ├─ local_decision
                ├─ remote_decision
                ├─ local ─┬─ check_loaded   (is the model resident?)
                │         ├─ swapping       (load it: seconds, budgeted per run)
                │         └─ infer
                ├─ remote
                ├─ remote_frontier
                └─ human
      committed · abstained · failed

  Each tier state requests one effect. Its result arrives as `:tier_done`, and the routing
  transitions on the parent `deciding` state commit it, move to the next tier in the plan, or
  abstain. Because every tier visited is a state entered and every result an event, the
  escalation path of each decision is in the OCEL log, ready for mining.

  Placement awareness (open question Q16): when the local model is **not** resident, an earlier
  tier's answer with confidence ≥ `policy.unloaded_accept` is committed instead of paying for a
  swap.

  2.0.0 (P4d): the tier states are named by kind and place (`Xeito.Tiers`); 1.x had
  `system_one`, `small`, `large`, `openrouter` and `remote`.

  Context (built by `Xeito.Escalation`): `type`, `input` (normalised), `plan` (remaining tiers),
  `policy`, `parent` (the requesting run), `base` (a `%Xeito.Decision{}` template), `attempts`.
  """

  use Xeito.Machine, version: "2.0.0"

  alias Xeito.Decider
  alias Xeito.Decision
  alias Xeito.Decision.Type
  alias Xeito.Effect

  @routable [:local_decision, :remote_decision, :local, :remote, :remote_frontier, :human]

  initial :deciding

  state :deciding, initial: :rules do
    on :tier_done, to: :committed, guard: :accept?, action: :commit

    for tier <- @routable do
      on :tier_done, to: tier, guard: :"next_#{tier}?", action: :advance
    end

    on :tier_done, to: :abstained, action: :abstain

    state :rules, entry: :run_rules, timeout: 5_000
    state :local_decision, entry: :run_local_decision, timeout: 10_000
    state :remote_decision, entry: :run_remote_decision, timeout: 30_000

    state :local, initial: :check_loaded do
      state :check_loaded, entry: :probe_local, timeout: 10_000 do
        on :probed, to: :infer, guard: :loaded?
        on :probed, to: :committed, guard: :accept_previous?, action: :commit_previous
        on :probed, to: :swapping, guard: :swap_allowed?

        for tier <- @routable -- [:local] do
          on :probed, to: tier, guard: :"skip_to_#{tier}?", action: :skip
        end

        on :probed, to: :abstained, action: :abstain_skipped
      end

      state :swapping, entry: :swap_local, timeout: 300_000 do
        on :swapped, to: :infer, guard: :swap_ok?

        for tier <- @routable -- [:local] do
          on :swapped, to: tier, guard: :"skip_to_#{tier}?", action: :skip
        end

        on :swapped, to: :abstained, action: :abstain_skipped
      end

      state :infer, entry: :run_local, timeout: 120_000
    end

    state :remote, entry: :run_remote, timeout: 90_000
    state :remote_frontier, entry: :run_remote_frontier, timeout: 180_000

    # --- entry functions: one effect per tier ------------------------------------------------

    state :human, timeout: {600_000, :human_timeout} do
      on :human_decision, to: :committed, guard: :valid_human?, action: :commit_human
      on :human_timeout, to: :abstained, action: :abstain_skipped
    end
  end

  final :committed
  final :abstained
  final :failed

  @doc false
  def run_rules(ctx), do: [tier_effect(:rules, ctx)]
  @doc false
  # --- guards ------------------------------------------------------------------------------
  def run_local_decision(ctx), do: [tier_effect(:local_decision, ctx)]
  @doc false
  def run_remote_decision(ctx), do: [tier_effect(:remote_decision, ctx)]
  @doc false
  def run_local(ctx), do: [tier_effect(:local, ctx)]
  @doc false
  def run_remote(ctx), do: [tier_effect(:remote, ctx)]
  @doc false
  def run_remote_frontier(ctx), do: [tier_effect(:remote_frontier, ctx)]
  @doc false
  def probe_local(ctx), do: [Effect.probe(:local, %{policy: ctx.policy, parent: ctx.parent})]
  @doc false
  def swap_local(ctx), do: [Effect.swap(:local, %{parent: ctx.parent})]

  defp tier_effect(tier, ctx), do: Effect.tier(tier, ctx.type, ctx.input)

  @doc false
  def accept?(ctx, result), do: Decider.accept?(Decision.type!(ctx.type), result)

  for tier <- @routable do
    @doc false
    def unquote(:"next_#{tier}?")(ctx, result), do: not accept?(ctx, result) and next?(ctx, unquote(tier))
  end

  for tier <- @routable -- [:local] do
    @doc false
    # --- actions -----------------------------------------------------------------------------
    def unquote(:"skip_to_#{tier}?")(ctx, _result), do: next?(ctx, unquote(tier))
  end

  defp next?(%{plan: [tier | _]}, tier), do: true
  defp next?(_ctx, _tier), do: false

  @doc false
  def loaded?(_ctx, probe), do: probe[:loaded] == true

  @doc false
  def swap_allowed?(_ctx, probe), do: probe[:loaded] == false and probe[:swap_allowed] == true

  @doc false
  def swap_ok?(_ctx, result), do: result[:ok] == true

  @doc false
  def accept_previous?(ctx, probe), do: probe[:loaded] == false and best_previous(ctx) != nil

  @doc false
  def valid_human?(ctx, %{value: value}), do: value in Type.values(Decision.type!(ctx.type))
  def valid_human?(_ctx, _data), do: false

  # The most confident earlier answer that clears `policy.unloaded_accept`, if any.
  defp best_previous(%{policy: %{unloaded_accept: min}} = ctx) when is_number(min) do
    ctx.attempts
    |> Enum.filter(&(is_number(&1[:confidence]) and &1.confidence >= min))
    |> Enum.max_by(& &1.confidence, fn -> nil end)
  end

  defp best_previous(_ctx), do: nil

  @doc false
  def commit(ctx, result), do: finish_with(ctx, [{:decided, result} | ctx.attempts])

  @doc false
  def commit_previous(ctx, _probe) do
    winner = best_previous(ctx)

    finish_with(ctx, [
      {:decided, Map.put(winner, :placement, :local_not_loaded)}
      | List.delete(ctx.attempts, winner)
    ])
  end

  @doc false
  def commit_human(ctx, %{value: value}) do
    human = %{
      tier: :human,
      value: value,
      confidence: 1.0,
      probabilities: %{value => 1.0},
      model: "human",
      latency_ms: 0
    }

    finish_with(ctx, [{:decided, human} | ctx.attempts])
  end

  @doc false
  def advance(ctx, result), do: %{ctx | attempts: [result | ctx.attempts], plan: tl(ctx.plan)}

  @doc false
  def skip(ctx, probe),
    do: %{ctx | attempts: [%{tier: :local, error: {:skipped, probe}} | ctx.attempts], plan: tl(ctx.plan)}

  @doc false
  def abstain(ctx, result), do: finish_with(ctx, [result | ctx.attempts])

  @doc false
  def abstain_skipped(ctx, data), do: finish_with(ctx, [%{tier: :local, error: {:skipped, data}} | ctx.attempts])

  defp finish_with(ctx, attempts) do
    decision = Decider.finalize(Decision.type!(ctx.type), ctx.base, attempts)
    %{ctx | attempts: attempts, decision: decision}
  end
end
