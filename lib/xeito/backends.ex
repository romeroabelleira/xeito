defmodule Xeito.Backends do
  @moduledoc """
  Behaviour and registry for model backends, the API a tier (`Xeito.Tiers`) speaks.

  | backend         | module                       | API                                                     |
  |-----------------|------------------------------|---------------------------------------------------------|
  | `:system_one`   | `Xeito.Backends.SystemOne`   | Jev-compatible `/v1/systemone` (e.g. laya-serve)        |
  | `:ollama`       | `Xeito.Backends.Ollama`      | Ollama `/api/chat`, JSON-schema format + logprobs       |
  | `:openrouter`   | `Xeito.Backends.OpenRouter`  | OpenAI-compatible chat completions, JSON schema + logprobs |

  `decide/3` takes a decision type, a normalised input and the tier's configuration, and returns
  the value, a probability per option, the model, latency and cost.
  """

  alias Xeito.Decision.Scoring
  alias Xeito.Decision.Type

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
    ollama: Xeito.Backends.Ollama,
    openrouter: Xeito.Backends.OpenRouter,
    system_one: Xeito.Backends.SystemOne
  }

  @doc "The backends, by name."
  @spec names() :: [atom()]
  def names, do: @modules |> Map.keys() |> Enum.sort()

  @doc "The module implementing a backend."
  @spec module(atom()) :: {:ok, module()} | :error
  def module(backend), do: Map.fetch(@modules, backend)

  @doc """
  Ollama `options` with `num_ctx` set from `cfg[:context]`, if configured.

  Every request to a tier must send the same value, or Ollama reloads the model.
  """
  @spec context_options(keyword(), map()) :: map()
  def context_options(cfg, options) do
    case Keyword.get(cfg, :context) do
      nil -> options
      context -> Map.put(options, :num_ctx, context)
    end
  end

  @doc "Builds a backend result from string-keyed option probabilities."
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
