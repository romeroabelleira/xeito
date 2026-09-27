defmodule Xeito.Machines.Escalation do
  @moduledoc """
  Delegation as a state machine: one run per decision request, walking the tiers of its plan
  (`docs/architecture/04-delegation.md`).

      deciding ─┬─ rules
                ├─ system_one
                ├─ small
                ├─ large ─┬─ check_loaded   (is the model resident?)
                │         ├─ swapping       (load it: seconds, budgeted per run)
                │         └─ infer
                ├─ openrouter
                ├─ remote
                └─ human
      committed · abstained · failed

  Each tier state requests one effect. Its result arrives as `:tier_done`, and the routing
  transitions on the parent `deciding` state commit it, move to the next tier in the plan, or
  abstain. Because every tier visited is a state entered and every result an event, the
  escalation path of each decision is in the OCEL log, ready for mining.

  Placement awareness (open question Q16): when the large model is **not** resident, an earlier
  small-tier answer with confidence ≥ `policy.unloaded_accept` is committed instead of paying for
  a swap.

  Context (built by `Xeito.Escalation`): `type`, `input` (normalised), `plan` (remaining tiers),
  `policy`, `parent` (the requesting run), `base` (a `%Xeito.Decision{}` template), `attempts`.
  """

  use Xeito.Machine, version: "1.1.0"

  alias Xeito.{Decider, Decision, Effect}
  alias Xeito.Decision.Type

  @routable [:system_one, :small, :large, :openrouter, :remote, :human]

  initial :deciding

  state :deciding, initial: :rules do
    on :tier_done, to: :committed, guard: :accept?, action: :commit

    for tier <- @routable do
      on :tier_done, to: tier, guard: :"next_#{tier}?", action: :advance
    end

    on :tier_done, to: :abstained, action: :abstain

    state :rules, entry: :run_rules, timeout: 5_000
    state :system_one, entry: :run_system_one, timeout: 10_000
    state :small, entry: :run_small, timeout: 30_000

    state :large, initial: :check_loaded do
      state :check_loaded, entry: :probe_large, timeout: 10_000 do
        on :probed, to: :infer, guard: :loaded?
        on :probed, to: :committed, guard: :accept_previous?, action: :commit_previous
        on :probed, to: :swapping, guard: :swap_allowed?

        for tier <- @routable -- [:large] do
          on :probed, to: tier, guard: :"skip_to_#{tier}?", action: :skip
        end

        on :probed, to: :abstained, action: :abstain_skipped
      end

      state :swapping, entry: :swap_large, timeout: 300_000 do
        on :swapped, to: :infer, guard: :swap_ok?

        for tier <- @routable -- [:large] do
          on :swapped, to: tier, guard: :"skip_to_#{tier}?", action: :skip
        end

        on :swapped, to: :abstained, action: :abstain_skipped
      end

      state :infer, entry: :run_large, timeout: 120_000
    end

    state :openrouter, entry: :run_openrouter, timeout: 90_000
    state :remote, entry: :run_remote, timeout: 180_000

    state :human, timeout: {600_000, :human_timeout} do
      on :human_decision, to: :committed, guard: :valid_human?, action: :commit_human
      on :human_timeout, to: :abstained, action: :abstain_skipped
    end
  end

  final :committed
  final :abstained
  final :failed

  # --- entry functions: one effect per tier ------------------------------------------------

  @doc false
  def run_rules(ctx), do: [tier_effect(:rules, ctx)]
  @doc false
  def run_system_one(ctx), do: [tier_effect(:system_one, ctx)]
  @doc false
  def run_small(ctx), do: [tier_effect(:small, ctx)]
  @doc false
  def run_large(ctx), do: [tier_effect(:large, ctx)]
  @doc false
  def run_openrouter(ctx), do: [tier_effect(:openrouter, ctx)]
  @doc false
  def run_remote(ctx), do: [tier_effect(:remote, ctx)]
  @doc false
  def probe_large(ctx), do: [Effect.probe(:large, %{policy: ctx.policy, parent: ctx.parent})]
  @doc false
  def swap_large(ctx), do: [Effect.swap(:large, %{parent: ctx.parent})]

  defp tier_effect(tier, ctx), do: Effect.tier(tier, ctx.type, ctx.input)

  # --- guards ------------------------------------------------------------------------------

  @doc false
  def accept?(ctx, result), do: Decider.accept?(Decision.type!(ctx.type), result)

  for tier <- @routable do
    @doc false
    def unquote(:"next_#{tier}?")(ctx, result),
      do: not accept?(ctx, result) and next?(ctx, unquote(tier))
  end

  for tier <- @routable -- [:large] do
    @doc false
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

  # --- actions -----------------------------------------------------------------------------

  @doc false
  def commit(ctx, result), do: finish_with(ctx, [{:decided, result} | ctx.attempts])

  @doc false
  def commit_previous(ctx, _probe) do
    winner = best_previous(ctx)

    finish_with(ctx, [
      {:decided, Map.put(winner, :placement, :large_not_loaded)}
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
    do: %{
      ctx
      | attempts: [%{tier: :large, error: {:skipped, probe}} | ctx.attempts],
        plan: tl(ctx.plan)
    }

  @doc false
  def abstain(ctx, result), do: finish_with(ctx, [result | ctx.attempts])

  @doc false
  def abstain_skipped(ctx, data),
    do: finish_with(ctx, [%{tier: :large, error: {:skipped, data}} | ctx.attempts])

  defp finish_with(ctx, attempts) do
    decision = Decider.finalize(Decision.type!(ctx.type), ctx.base, attempts)
    %{ctx | attempts: attempts, decision: decision}
  end
end
