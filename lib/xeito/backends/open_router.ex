defmodule Xeito.Backends.OpenRouter do
  @moduledoc """
  OpenRouter backend: decisions on hosted models through `POST /api/v1/chat/completions`, for the remote tiers.

  Request:
    * the decision's JSON Schema as `response_format` (`strict: true`), temperature 0, no reasoning
    * `logprobs` with `top_logprobs` (at most 20), unless `logprobs: false`
    * `provider`: `require_parameters: true` (endpoints must honour the schema and, when asked,
      return logprobs), `data_collection: "deny"`, `zdr` (default `true`); `cfg[:providers]`
      sets `provider.only`

  Result:
    * confidence from the value's first-token `top_logprobs`, as `Xeito.Backends.Ollama.probabilities/3`
    * no logprobs: a `terminal: true` result without confidence
    * a refusal is an error
    * cost is OpenRouter's `usage.cost` (USD) plus token counts; `model` is `openrouter:<model>@<provider>`

  The request and its reading are `Xeito.Backends.OpenAI`'s; this module adds the `provider`
  routing and `reasoning`. Chat (`chat/4`) is `Xeito.Chat.OpenRouter`'s. OpenRouter bills each
  call and reports a key's allowance (`spend/0` is `:billed`, `Xeito.Allowance`).

  `Xeito.Policy` gates every tier that uses it, as every off-box tier.
  """

  @behaviour Xeito.Backends

  alias Xeito.Backends
  alias Xeito.Backends.OpenAI

  @impl true
  def decide(type, input, cfg), do: OpenAI.ask(type, body(type, input, cfg), cfg, name: :openrouter, headers: headers())

  @impl true
  def chat(messages, tools, cfg, on_delta), do: Xeito.Chat.OpenRouter.complete(messages, tools, cfg, on_delta)

  @impl true
  def default_url, do: "https://openrouter.ai/api"

  @impl true
  def spend, do: :billed

  @impl true
  def destination(_cfg), do: "OpenRouter, zero data retention"

  @doc false
  def body(type, input, cfg) do
    provider =
      then(
        %{require_parameters: true, data_collection: "deny", zdr: Keyword.get(cfg, :zdr, true)},
        &if(cfg[:providers], do: Map.put(&1, :only, cfg[:providers]), else: &1)
      )

    Map.merge(OpenAI.body(type, input, cfg), %{reasoning: %{enabled: false}, provider: provider})
  end

  defp headers, do: [{"x-openrouter-title", "Xeito"}]

  @doc false
  defdelegate cost(usage), to: OpenAI

  @doc "The API key's limits and usage (`GET /api/v1/key`); spends nothing."
  @spec key_info(keyword()) :: {:ok, map()} | {:error, term()}
  def key_info(cfg) do
    case Req.request([method: :get, url: "/v1/key"] ++ Backends.req_options(cfg)) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
