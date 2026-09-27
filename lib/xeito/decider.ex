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

  alias Xeito.{Decision, Tiers}
  alias Xeito.Decision.Type

  @doc """
  Decides `type_module` for `input`. Options: `:deciders` (tier list), `:tiers` (config
  overrides per tier, e.g. `[small: [url: ...]]`).
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
          type |> try_tiers(normalized, opts) |> to_decision(base) |> apply_floor(type)
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
    case Tiers.config(tier, overrides) do
      nil -> {:error, :tier_unavailable}
      cfg -> Tiers.module(tier).decide(type, normalized, cfg)
    end
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

      if Map.get(attempt, :confidence, 0) >= Type.threshold(type, tier),
        do: {:halt, [{:decided, attempt} | attempts]},
        else: {:cont, [attempt | attempts]}
    end)
  end

  defp to_decision([{:decided, winner} | rest], base) do
    %{
      base
      | value: winner.value,
        confidence: winner.confidence,
        probabilities: winner.probabilities,
        actor: winner.tier,
        model: winner.model,
        evidence: Enum.reverse(rest) |> Enum.map(&evidence/1)
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

  defp evidence(%{error: _} = attempt), do: attempt
  defp evidence(attempt), do: Map.take(attempt, [:tier, :value, :confidence, :model, :latency_ms])

  defp apply_floor(decision, %Type{severity: nil}), do: decision

  defp apply_floor(%Decision{value: value} = decision, %Type{
         severity: %{order: order, floor: floor}
       }) do
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
