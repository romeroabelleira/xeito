defmodule Xeito.Tiers.OpenRouter do
  @moduledoc """
  OpenRouter tier: hosted **open-weight** models through OpenRouter's OpenAI-compatible
  `POST /api/v1/chat/completions`, with token log-probabilities for a calibrated confidence.

  It fills the gap between the local large tier and the remote Claude tier: models too large
  for the local GPU, or the local large model's own family without a swap, answering with a
  confidence the escalation can threshold. Claude stays on the direct Anthropic tier
  (`Xeito.Tiers.Remote`); through OpenRouter it would lose the server-side refusal fallback and
  still return no logprobs (`docs/architecture/04-delegation.md#openrouter`).

  Request:
    * `response_format` is the decision's JSON Schema (`strict: true`), at temperature 0 with
      reasoning disabled, and `logprobs` with `top_logprobs` (≤ 20).
    * `provider.require_parameters: true`, so only provider endpoints that honour the schema
      **and** return logprobs are used. `provider.data_collection: "deny"` and `provider.zdr`
      (default `true`) restrict routing to endpoints that neither train on nor retain prompts.
      `cfg[:providers]` pins providers (`provider.only`).

  Result: the confidence comes from the `top_logprobs` at the value's first token, as for the
  local large tier (`Xeito.Tiers.Large.probabilities/3`). An endpoint that returns no logprobs
  yields a `terminal: true` result without confidence. A refusal is an error. Cost is
  OpenRouter's own `usage.cost` (USD), plus token counts; the model provenance names the
  provider endpoint that served the request (`openrouter:<model>@<provider>`).

  Off-box: `Xeito.Policy` gates this tier exactly like `:remote`.
  """

  @behaviour Xeito.Tiers

  alias Xeito.Decision.{Prompt, Type}
  alias Xeito.Tiers
  alias Xeito.Tiers.Large

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
        Tiers.req_options(Keyword.put_new(cfg, :timeout, 60_000))

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
      %{
        require_parameters: true,
        data_collection: "deny",
        zdr: Keyword.get(cfg, :zdr, true)
      }
      |> then(&if(cfg[:providers], do: Map.put(&1, :only, cfg[:providers]), else: &1))

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
      logprobs: true,
      top_logprobs: min(Keyword.get(cfg, :top_logprobs, 20), 20),
      provider: provider
    }
  end

  defp headers, do: [{"x-openrouter-title", "Xeito"}]

  defp parse(_type, %{"message" => %{"refusal" => refusal}}, _resp, _model, _started)
       when is_binary(refusal) and refusal != "",
       do: {:error, {:refusal, refusal}}

  defp parse(type, choice, resp, model, started) do
    content = get_in(choice, ["message", "content"]) || ""
    served_by = served_by(resp["model"] || model, resp["provider"])
    cost = cost(resp["usage"] || %{})

    case get_in(choice, ["logprobs", "content"]) do
      [_ | _] = logprobs ->
        type |> probabilities(content, logprobs) |> result(type, served_by, started, cost)

      _ ->
        terminal(type, content, served_by, started, cost)
    end
  end

  defp probabilities(type, content, logprobs), do: Large.probabilities(content, logprobs, type)

  defp result(probs, type, model, started, cost),
    do: Tiers.result(type, probs, model, started, cost)

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

  # Provenance names the model and the provider endpoint that served it.
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

  @doc """
  The API key's limits and usage (`GET /api/v1/key`). Free: a health check that spends nothing.
  """
  @spec key_info(keyword()) :: {:ok, map()} | {:error, term()}
  def key_info(cfg) do
    case Req.request([method: :get, url: "/v1/key"] ++ Tiers.req_options(cfg)) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
