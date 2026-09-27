defmodule Xeito.Tiers do
  @moduledoc """
  Decider backends (rules, System One, small, large, remote, human) and the escalation machine.

  Every model tier implements `decide/3`: given a decision type, a normalised input and the
  tier's configuration, it returns the value, a probability for every option, and provenance.
  Configuration comes from `config :xeito, :tiers` (see `config/runtime.exs`); a tier without
  a `:url` is unavailable.

  | tier          | module                   | backend                                        |
  |---------------|--------------------------|------------------------------------------------|
  | `:system_one` | `Xeito.Tiers.SystemOne`  | Jev-compatible `/v1/systemone` (e.g. laya-serve) |
  | `:small`      | `Xeito.Tiers.Small`      | llama-server, prefilled value + logprob scoring |
  | `:large`      | `Xeito.Tiers.Large`      | Ollama `/api/chat`, JSON-schema format + logprobs |

  P2 tries tiers in order (`Xeito.Decider`). The escalation machine with policies and budgets
  arrives in P3. See `docs/architecture/04-delegation.md`.
  """

  alias Xeito.Decision.{Scoring, Type}

  @type result :: %{
          value: atom(),
          probabilities: %{atom() => float()},
          confidence: float(),
          model: String.t(),
          latency_ms: non_neg_integer()
        }

  @callback decide(Type.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}

  @modules %{
    system_one: Xeito.Tiers.SystemOne,
    small: Xeito.Tiers.Small,
    large: Xeito.Tiers.Large
  }

  @doc "The module implementing a tier."
  @spec module(atom()) :: module()
  def module(tier), do: Map.fetch!(@modules, tier)

  @doc "The configuration of a tier, merged with overrides; `nil` if the tier has no URL."
  @spec config(atom(), keyword()) :: keyword() | nil
  def config(tier, overrides \\ []) do
    cfg =
      :xeito
      |> Application.get_env(:tiers, [])
      |> Keyword.get(tier, [])
      |> Keyword.merge(overrides)

    if cfg[:url], do: cfg, else: nil
  end

  @doc "Builds a tier result from string-keyed option probabilities."
  @spec result(Type.t(), %{String.t() => float()}, String.t(), integer()) ::
          {:ok, result()} | {:error, term()}
  def result(type, string_probs, model, started_at) do
    probs =
      for {k, p} <- string_probs, {:ok, atom} <- [Type.cast(type, k)], into: %{}, do: {atom, p}

    case Scoring.top(probs) do
      nil ->
        {:error, :no_probability_mass_on_options}

      {value, confidence} ->
        {:ok,
         %{
           value: value,
           probabilities: probs,
           confidence: confidence,
           model: model,
           latency_ms: System.monotonic_time(:millisecond) - started_at
         }}
    end
  end

  @doc "Common Req options: base URL, bearer key, timeouts, no retries."
  @spec req_options(keyword()) :: keyword()
  def req_options(cfg) do
    auth = if cfg[:api_key], do: [auth: {:bearer, cfg[:api_key]}], else: []

    [base_url: cfg[:url], receive_timeout: Keyword.get(cfg, :timeout, 60_000), retry: false] ++
      auth ++ Keyword.take(cfg, [:plug])
  end
end
