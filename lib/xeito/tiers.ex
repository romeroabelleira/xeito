defmodule Xeito.Tiers do
  @moduledoc """
  Decider backends (rules, System One, small, large, OpenRouter, remote, human) and the escalation machine.

  Every tier implements `decide/3`: given a decision type, a normalised input and the tier's
  configuration, it returns the value, a probability for every option, provenance and cost.
  Configuration comes from `config :xeito, :tiers` (see `config/runtime.exs`); a model tier
  without a `:url` is unavailable.

  | tier          | module                   | backend                                                 |
  |---------------|--------------------------|---------------------------------------------------------|
  | `:rules`      | `Xeito.Tiers.Rules`      | the type's deterministic rules                          |
  | `:system_one` | `Xeito.Tiers.SystemOne`  | Jev-compatible `/v1/systemone` (e.g. laya-serve)        |
  | `:small`      | `Xeito.Tiers.Small`      | llama-server, prefilled value + one-token scoring       |
  | `:large`      | `Xeito.Tiers.Large`      | Ollama `/api/chat`, JSON-schema format + logprobs       |
  | `:openrouter` | `Xeito.Tiers.OpenRouter` | hosted open-weight models, JSON schema + logprobs, policy-gated |
  | `:remote`     | `Xeito.Tiers.Remote`     | Anthropic Messages API, structured output, policy-gated |

  At run time, `Xeito.Machines.Escalation` walks the tiers as a logged state machine under
  `Xeito.Policy`. `Xeito.Decider` is the same ladder in-process, used by evaluation.
  See `docs/architecture/04-delegation.md`.
  """

  alias Xeito.Decision.Scoring
  alias Xeito.Decision.Type
  alias Xeito.Tiers.Queue

  @type result :: %{
          required(:value) => atom(),
          required(:probabilities) => %{atom() => float()},
          required(:confidence) => float() | nil,
          required(:model) => String.t(),
          required(:latency_ms) => non_neg_integer(),
          optional(:cost) => map(),
          optional(:terminal) => boolean()
        }

  @callback decide(Type.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}

  @modules %{
    rules: Xeito.Tiers.Rules,
    system_one: Xeito.Tiers.SystemOne,
    small: Xeito.Tiers.Small,
    large: Xeito.Tiers.Large,
    openrouter: Xeito.Tiers.OpenRouter,
    remote: Xeito.Tiers.Remote
  }

  # Estimated average power while a tier works (joules = watts × seconds). An estimate, not a
  # measurement; deployment-specific values belong in `config :xeito, :tier_watts`. Off-box
  # tiers count 0 here: their energy is spent elsewhere and not measurable from this machine.
  @default_watts %{rules: 0, system_one: 45, small: 65, large: 300, openrouter: 0, remote: 0}

  @doc "The module implementing a tier."
  @spec module(atom()) :: module()
  def module(tier), do: Map.fetch!(@modules, tier)

  @doc "The configuration of a tier, merged with overrides; `nil` if a model tier has no URL."
  @spec config(atom(), keyword()) :: keyword() | nil
  def config(tier, overrides \\ [])
  def config(:rules, overrides), do: overrides

  def config(tier, overrides) do
    cfg =
      :xeito
      |> Application.get_env(:tiers, [])
      |> Keyword.get(tier, [])
      |> Keyword.merge(overrides)

    if cfg[:url], do: cfg
  end

  @doc """
  Ollama `options` with the configured context window (`cfg[:context]`, `num_ctx`) added. Every
  request to the large tier (chat, decisions, a model load) sends the same value, so they share
  one loaded model instead of reloading it for each other, and the chat machine's budget is the
  server's window by construction. Without `:context`, the server's own setting applies.
  """
  @spec context_options(keyword(), map()) :: map()
  def context_options(cfg, options) do
    case Keyword.get(cfg, :context) do
      nil -> options
      context -> Map.put(options, :num_ctx, context)
    end
  end

  @doc """
  Runs one tier for a decision: resolves its configuration, waits for a capacity slot
  (`Xeito.Tiers.Queue`), calls the backend, and completes the cost with an energy estimate.
  """
  @spec run(atom(), Type.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(tier, type, input, overrides \\ []) do
    case config(tier, overrides) do
      nil ->
        {:error, :tier_unavailable}

      cfg ->
        tier
        |> Queue.run(fn -> module(tier).decide(type, input, cfg) end)
        |> add_energy(tier)
    end
  end

  defp add_energy({:ok, result}, tier) do
    watts =
      :xeito
      |> Application.get_env(:tier_watts, %{})
      |> Map.get(tier, Map.fetch!(@default_watts, tier))

    joules = Float.round(watts * result.latency_ms / 1000, 3)
    {:ok, Map.update(result, :cost, %{joules_est: joules}, &Map.put(&1, :joules_est, joules))}
  end

  defp add_energy(error, _tier), do: error

  @doc "Builds a tier result from string-keyed option probabilities."
  @spec result(Type.t(), %{String.t() => float()}, String.t(), integer(), map()) ::
          {:ok, result()} | {:error, term()}
  def result(type, string_probs, model, started_at, cost \\ %{}) do
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
           latency_ms: System.monotonic_time(:millisecond) - started_at,
           cost: cost
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
