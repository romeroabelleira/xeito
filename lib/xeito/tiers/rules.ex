defmodule Xeito.Tiers.Rules do
  @moduledoc "The rules tier: the decision type's deterministic rules, as a tier (confidence 1.0)."

  @behaviour Xeito.Tiers

  alias Xeito.Decider

  @impl true
  def decide(type, input, _cfg) do
    case Decider.apply_rules(type, input) do
      {:ok, value, rule} ->
        {:ok,
         %{
           value: value,
           probabilities: %{value => 1.0},
           confidence: 1.0,
           model: "rule:#{rule}",
           latency_ms: 0,
           cost: %{}
         }}

      :none ->
        {:error, :no_rule}
    end
  end
end
