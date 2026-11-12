defmodule Xeito.Backends do
  @moduledoc """
  Behaviour and registry for model backends: each is one way of reaching a model, a strategy a tier (`Xeito.Tiers`) names.

  | backend       | module                      | API                                                          |
  |---------------|-----------------------------|--------------------------------------------------------------|
  | `:anthropic`  | `Xeito.Backends.Anthropic`  | the Claude API's `/v1/messages`, JSON schema, no logprobs    |
  | `:colibri`    | `Xeito.Backends.Colibri`    | Colibri: `/v1/systemone` decisions, OpenAI chat completions  |
  | `:ollama`     | `Xeito.Backends.Ollama`     | Ollama `/api/chat`, JSON-schema format + logprobs            |
  | `:openai`     | `Xeito.Backends.OpenAI`     | any OpenAI-compatible chat completions server                |
  | `:openrouter` | `Xeito.Backends.OpenRouter` | OpenRouter: chat completions, provider routing, billed cost  |
  | `:system_one` | `Xeito.Backends.SystemOne`  | Jev-compatible `/v1/systemone` (e.g. laya-serve)             |

  `config :xeito, :backends`, a map of name to module, adds backends to these.

  A backend answers what differs between services, and callers ask it through this module
  instead of matching its name. `decide/3` is required; for the rest a backend that lacks the
  callback gets the default:

  | callback        | question                                             | default                        |
  |-----------------|------------------------------------------------------|--------------------------------|
  | `decide/3`      | a typed decision with a probability per option       | required                       |
  | `chat/4`        | one streamed model call with tools                   | `{:error, {:no_chat_backend, name}}` |
  | `probe/2`       | whether the service answers and what it holds        | `%{}`                          |
  | `loaded?/1`     | whether the tier's model is resident                 | `{:ok, true}`: it serves one   |
  | `load/1`        | make it resident; milliseconds taken                 | `{:ok, 0}`                     |
  | `default_url/0` | the service's public URL                             | `nil`: the tier must set one   |
  | `spend/0`       | how a call's cost is known: `:billed` (reported by the service, against a key's allowance) or `:priced` (from list prices) | `:none`: no cost is known |
  | `list_price/1`  | the model's list price, for a `:priced` backend      | `nil`                          |
  | `destination/1` | where a conversation goes, for the notice of `/model` | the backend's name and URL    |
  """

  alias Xeito.Chat.Message
  alias Xeito.Decision.Scoring
  alias Xeito.Decision.Type

  @type result :: %{
          required(:value) => atom(),
          required(:probabilities) => %{atom() => float()},
          required(:confidence) => float() | nil,
          required(:model) => String.t(),
          required(:latency_ms) => non_neg_integer(),
          optional(:cost) => map(),
          optional(:terminal) => boolean(),
          optional(:backend) => atom()
        }

  @type spend :: :billed | :priced | :none

  @callback decide(Type.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  @callback chat([Message.t()], [map()], keyword(), (String.t() -> any())) :: {:ok, Message.reply()} | {:error, term()}
  @callback probe(keyword(), keyword()) :: map()
  @callback loaded?(keyword()) :: {:ok, boolean()} | {:error, term()}
  @callback load(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback default_url() :: String.t()
  @callback spend() :: spend()
  @callback list_price(keyword()) :: map() | nil
  @callback destination(keyword()) :: String.t()

  @optional_callbacks chat: 4, probe: 2, loaded?: 1, load: 1, default_url: 0, spend: 0, list_price: 1, destination: 1

  @modules %{
    anthropic: Xeito.Backends.Anthropic,
    colibri: Xeito.Backends.Colibri,
    ollama: Xeito.Backends.Ollama,
    openai: Xeito.Backends.OpenAI,
    openrouter: Xeito.Backends.OpenRouter,
    system_one: Xeito.Backends.SystemOne
  }

  @doc "The backends, by name."
  @spec names() :: [atom()]
  def names, do: modules() |> Map.keys() |> Enum.sort()

  @doc "The module implementing a backend."
  @spec module(atom()) :: {:ok, module()} | :error
  def module(backend), do: Map.fetch(modules(), backend)

  defp modules, do: Map.merge(@modules, Application.get_env(:xeito, :backends, %{}))

  # The backend's module, if it has the callback.
  defp implementing(backend, callback, arity) do
    with {:ok, module} <- module(backend),
         true <- Code.ensure_loaded?(module) and function_exported?(module, callback, arity) do
      {:ok, module}
    else
      _ -> :error
    end
  end

  @doc "One streamed model call with tools on `backend`; an error if it cannot chat."
  @spec chat(atom(), [Message.t()], [map()], keyword(), (String.t() -> any())) ::
          {:ok, Message.reply()} | {:error, term()}
  def chat(backend, messages, tools, cfg, on_delta) do
    case implementing(backend, :chat, 4) do
      {:ok, module} -> module.chat(messages, tools, cfg, on_delta)
      :error -> {:error, {:no_chat_backend, backend}}
    end
  end

  @doc "What the monitor shows of the service behind `cfg`; options `:timeout` and `:now`."
  @spec probe(atom(), keyword(), keyword()) :: map()
  def probe(backend, cfg, opts) do
    case implementing(backend, :probe, 2) do
      {:ok, module} -> module.probe(cfg, opts)
      :error -> %{}
    end
  end

  @doc "Whether the tier's model is resident; a backend without residency always holds its model."
  @spec loaded?(atom(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def loaded?(backend, cfg) do
    case implementing(backend, :loaded?, 1) do
      {:ok, module} -> module.loaded?(cfg)
      :error -> {:ok, true}
    end
  end

  @doc "Makes the tier's model resident; `{:ok, milliseconds}`."
  @spec load(atom(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load(backend, cfg) do
    case implementing(backend, :load, 1) do
      {:ok, module} -> module.load(cfg)
      :error -> {:ok, 0}
    end
  end

  @doc "The URL a tier on `backend` uses when it sets none."
  @spec default_url(atom()) :: String.t() | nil
  def default_url(backend) do
    case implementing(backend, :default_url, 0) do
      {:ok, module} -> module.default_url()
      :error -> nil
    end
  end

  @doc "How a call's cost on `backend` is known."
  @spec spend(atom()) :: spend()
  def spend(backend) do
    case implementing(backend, :spend, 0) do
      {:ok, module} -> module.spend()
      :error -> :none
    end
  end

  @doc "The list price of the model in `cfg`, on a `:priced` backend."
  @spec list_price(atom(), keyword()) :: map() | nil
  def list_price(backend, cfg) do
    case implementing(backend, :list_price, 1) do
      {:ok, module} -> module.list_price(cfg)
      :error -> nil
    end
  end

  @doc "Where a conversation on `backend` goes, for the notice of a switch."
  @spec destination(atom(), keyword()) :: String.t()
  def destination(backend, cfg) do
    case implementing(backend, :destination, 1) do
      {:ok, module} -> module.destination(cfg)
      :error -> "#{backend} at #{cfg[:url]}"
    end
  end

  @doc "One GET of a service's status path, bounded by `timeout`; the decoded body of a 200."
  @spec get(keyword(), String.t(), pos_integer()) :: {:ok, term()} | {:error, {:http, pos_integer()} | :unreachable}
  def get(cfg, path, timeout) do
    opts = [method: :get, url: path] ++ req_options(Keyword.put(cfg, :timeout, timeout))

    case Req.request(Keyword.put(opts, :connect_options, timeout: timeout)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, _reason} -> {:error, :unreachable}
    end
  end

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
