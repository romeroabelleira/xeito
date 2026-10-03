defmodule Xeito.Backends do
  @moduledoc """
  Model backends: the API a tier speaks. A tier (`Xeito.Tiers`) is a place on the escalation
  ladder; its configuration names a backend, a URL, a model and a key.

  | backend         | module                       | API                                                     |
  |-----------------|------------------------------|---------------------------------------------------------|
  | `:system_one`   | `Xeito.Backends.SystemOne`   | Jev-compatible `/v1/systemone` (e.g. laya-serve)        |
  | `:llama_server` | `Xeito.Backends.LlamaServer` | llama-server, prefilled value + one-token scoring       |
  | `:ollama`       | `Xeito.Backends.Ollama`      | Ollama `/api/chat`, JSON-schema format + logprobs       |
  | `:openrouter`   | `Xeito.Backends.OpenRouter`  | OpenAI-compatible chat completions, JSON schema + logprobs |
  | `:anthropic`    | `Xeito.Backends.Anthropic`   | Anthropic Messages API, structured output               |

  Every backend implements `decide/3`: given a decision type, a normalised input and the tier's
  configuration, it returns the value, a probability for every option, provenance and cost.
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
    system_one: Xeito.Backends.SystemOne,
    llama_server: Xeito.Backends.LlamaServer,
    ollama: Xeito.Backends.Ollama,
    openrouter: Xeito.Backends.OpenRouter,
    anthropic: Xeito.Backends.Anthropic
  }

  @doc "The module implementing a backend."
  @spec module(atom()) :: {:ok, module()} | :error
  def module(backend), do: Map.fetch(@modules, backend)

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
