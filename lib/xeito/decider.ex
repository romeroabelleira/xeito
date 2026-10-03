defmodule Xeito.Decider do
  @moduledoc """
  Evaluates a decision type for one input:

    1. **Rules** (deterministic, declared on the type) — the first rule that fires decides,
       with `actor: :rule` and confidence 1.0.
    2. **Tiers** in order (`opts[:deciders]` or the type's `deciders`) — the first result whose
       confidence reaches the tier's threshold decides. Unavailable tiers are skipped.
    3. Otherwise the decision is **`:abstain`**, with every attempt kept as evidence.

  For types with a `severity` order, the model result is raised to at least the floor. A model
  can make a monotonic decision more cautious, never less (`Risk`).

  P2 tries tiers in a fixed order. The escalation machine (policies, budgets, swaps) replaces
  step 2 in P3.
  """

  alias Xeito.Decision
  alias Xeito.Decision.Type
  alias Xeito.Tiers

  @doc """
  Decides `type_module` for `input`. Options: `:deciders` (tier list), `:tiers` (config
  overrides per tier, e.g. `[local: [url: ...]]`).
  """
  @spec decide(module(), map(), keyword()) :: Decision.t()
  def decide(type_module, input, opts \\ []) do
    type = Decision.type!(type_module)
    started = System.monotonic_time(:millisecond)
    normalized = Type.normalize_input(type, input)

    base = %Decision{
      type: type_module,
      type_version: type.version,
      value: :abstain,
      input_hash: Type.input_hash(type, normalized)
    }

    decision =
      case apply_rules(type, normalized) do
        {:ok, value, fun} ->
          %{
            base
            | value: value,
              confidence: 1.0,
              actor: :rule,
              model: "rule:#{fun}",
              probabilities: %{value => 1.0}
          }

        :none ->
          finalize(type, base, try_tiers(type, normalized, opts))
      end

    %{decision | latency_ms: System.monotonic_time(:millisecond) - started}
  end

  @doc "Evaluates only the rules. Returns `{:ok, value, rule}` or `:none`."
  @spec apply_rules(Type.t(), map()) :: {:ok, atom(), atom()} | :none
  def apply_rules(type, input) do
    Enum.find_value(type.rules, :none, fn %{fun: fun, then: then} ->
      case {apply(type.module, fun, [input]), then} do
        {true, value} when not is_nil(value) ->
          {:ok, value, fun}

        {value, nil} when is_atom(value) and not is_nil(value) and not is_boolean(value) ->
          {:ok, value, fun}

        _ ->
          nil
      end
    end)
  end

  @doc "Runs one tier directly (for evaluation). Returns the tier result or an error."
  @spec run_tier(Type.t(), atom(), map(), keyword()) :: {:ok, Tiers.result()} | {:error, term()}
  def run_tier(type, tier, normalized, overrides \\ []) do
    Tiers.run(tier, type, normalized, overrides)
  end

  defp try_tiers(type, normalized, opts) do
    tiers = Keyword.get(opts, :deciders, type.deciders)
    overrides = Keyword.get(opts, :tiers, [])

    Enum.reduce_while(tiers, [], fn tier, attempts ->
      attempt =
        case run_tier(type, tier, normalized, Keyword.get(overrides, tier, [])) do
          {:ok, result} -> Map.put(result, :tier, tier)
          {:error, reason} -> %{tier: tier, error: reason}
        end

      if accept?(type, attempt),
        do: {:halt, [{:decided, attempt} | attempts]},
        else: {:cont, [attempt | attempts]}
    end)
  end

  @doc """
  Whether a tier attempt decides: a value whose confidence reaches the tier's threshold, or a
  terminal result (a tier without calibrated confidence that policy has already admitted).
  """
  @spec accept?(Type.t(), map()) :: boolean()
  def accept?(type, %{tier: tier} = attempt) do
    case attempt do
      %{error: _} -> false
      %{terminal: true, value: _} -> true
      %{confidence: c} when is_number(c) -> c >= Type.threshold(type, tier)
      _ -> false
    end
  end

  @doc """
  Builds the decision from the attempts (most recent first; a `{:decided, attempt}` head marks
  the winner), sums their costs, and applies the type's severity floor.
  """
  @spec finalize(Type.t(), Decision.t(), list()) :: Decision.t()
  def finalize(type, base, attempts) do
    all =
      Enum.map(attempts, fn
        {:decided, a} -> a
        a -> a
      end)

    attempts
    |> to_decision(base)
    |> Map.put(:cost, total_cost(all))
    |> apply_floor(type)
  end

  defp total_cost(attempts) do
    attempts
    |> Enum.map(&Map.get(&1, :cost, %{}))
    |> Enum.reduce(%{}, fn cost, acc -> Map.merge(acc, cost, fn _k, a, b -> a + b end) end)
  end

  defp to_decision([{:decided, winner} | rest], base) do
    %{
      base
      | value: winner.value,
        confidence: winner.confidence,
        probabilities: winner.probabilities,
        actor: actor(winner.tier),
        model: winner.model,
        evidence: rest |> Enum.reverse() |> Enum.map(&evidence/1)
    }
  end

  defp to_decision(attempts, base) do
    %{
      base
      | value: :abstain,
        actor: :none,
        evidence: attempts |> Enum.reverse() |> Enum.map(&evidence/1)
    }
  end

  # Tiers are named after their backend; the decision's actor names who decided.
  defp actor(:rules), do: :rule
  defp actor(tier), do: tier

  defp evidence(%{error: _} = attempt), do: attempt
  defp evidence(attempt), do: Map.take(attempt, [:tier, :value, :confidence, :model, :latency_ms])

  defp apply_floor(decision, %Type{severity: nil}), do: decision

  # The floor bounds what a *model* may decide. Rules and humans are authoritative.
  defp apply_floor(%Decision{actor: actor} = decision, _type) when actor in [:rule, :human], do: decision

  defp apply_floor(%Decision{value: value} = decision, %Type{severity: %{order: order, floor: floor}}) do
    raised =
      if value == :abstain,
        do: floor,
        else: Enum.max_by([value, floor], &Enum.find_index(order, fn v -> v == &1 end))

    if raised == value,
      do: decision,
      else: %{
        decision
        | value: raised,
          evidence: decision.evidence ++ [%{floor: floor, model_value: value}]
      }
  end
end
