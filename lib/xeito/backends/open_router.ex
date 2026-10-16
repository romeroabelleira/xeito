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

  `Xeito.Policy` gates every tier that uses it, as every off-box tier.
  """

  @behaviour Xeito.Backends

  alias Xeito.Backends
  alias Xeito.Backends.Ollama
  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Type

  @impl true
  def decide(type, input, cfg) do
    started = System.monotonic_time(:millisecond)
    model = Keyword.fetch!(cfg, :model)

    opts =
      [
        method: :post,
        url: "/v1/chat/completions",
        json: body(type, input, cfg),
        headers: headers()
      ] ++
        Backends.req_options(Keyword.put_new(cfg, :timeout, 60_000))

    case Req.request(opts) do
      {:ok, %{status: 200, body: %{"choices" => [choice | _]} = resp}} ->
        parse(type, choice, resp, model, started)

      {:ok, %{status: 200, body: %{"error" => error}}} ->
        {:error, {:openrouter, error}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def body(type, input, cfg) do
    provider =
      then(
        %{require_parameters: true, data_collection: "deny", zdr: Keyword.get(cfg, :zdr, true)},
        &if(cfg[:providers], do: Map.put(&1, :only, cfg[:providers]), else: &1)
      )

    Map.merge(
      %{
        model: Keyword.fetch!(cfg, :model),
        messages: Prompt.messages(type, input),
        response_format: %{
          type: "json_schema",
          json_schema: %{name: type.name, strict: true, schema: Prompt.json_schema(type)}
        },
        temperature: 0,
        max_tokens: Keyword.get(cfg, :max_tokens, 64),
        reasoning: %{enabled: false},
        provider: provider
      },
      logprobs(cfg)
    )
  end

  # Without logprobs, `require_parameters` also admits endpoints that cannot return them; the answer is terminal.
  defp logprobs(cfg) do
    if Keyword.get(cfg, :logprobs, true),
      do: %{logprobs: true, top_logprobs: min(Keyword.get(cfg, :top_logprobs, 20), 20)},
      else: %{}
  end

  defp headers, do: [{"x-openrouter-title", "Xeito"}]

  defp parse(_type, %{"message" => %{"refusal" => refusal}}, _resp, _model, _started)
       when is_binary(refusal) and refusal != "", do: {:error, {:refusal, refusal}}

  defp parse(type, choice, resp, model, started) do
    content = get_in(choice, ["message", "content"]) || ""
    {served_by, cost} = served_and_cost(resp, model)

    case get_in(choice, ["logprobs", "content"]) do
      [_ | _] = logprobs ->
        type |> probabilities(content, logprobs) |> result(type, served_by, started, cost)

      _ ->
        terminal(type, content, served_by, started, cost)
    end
  end

  defp served_and_cost(resp, model), do: {served_by(resp["model"] || model, resp["provider"]), cost(resp["usage"] || %{})}

  defp probabilities(type, content, logprobs), do: Ollama.probabilities(content, logprobs, type)

  defp result(probs, type, model, started, cost), do: Backends.result(type, probs, model, started, cost)

  defp terminal(type, content, model, started, cost) do
    with {:ok, %{"value" => raw}} <- JSON.decode(content),
         {:ok, value} <- Type.cast(type, raw) do
      {:ok,
       %{
         value: value,
         probabilities: %{},
         confidence: nil,
         terminal: true,
         model: model,
         latency_ms: System.monotonic_time(:millisecond) - started,
         cost: cost
       }}
    else
      _ -> {:error, {:unparseable, content}}
    end
  end

  defp served_by(model, nil), do: "openrouter:" <> model
  defp served_by(model, provider), do: "openrouter:#{model}@#{provider}"

  @doc false
  def cost(usage) do
    %{
      tokens_in: usage["prompt_tokens"] || 0,
      tokens_out: usage["completion_tokens"] || 0,
      usd: usage["cost"] || 0.0
    }
  end

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
