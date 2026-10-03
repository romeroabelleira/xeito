defmodule Xeito.Backends.Anthropic do
  @moduledoc """
  Anthropic backend: the Messages API over raw HTTP (there is no official Elixir SDK).

  * The model is `cfg[:model]`, default `claude-opus-5`. Output is constrained with
    `output_config.format` (`json_schema` with the decision's enum). The request runs at
    `effort: "low"`, which suits a classification.
  * Server-side refusal fallback is enabled (`fallbacks: "default"`, beta
    `server-side-fallback-2026-07-01`). A final `stop_reason: "refusal"` is an error, not a value.
  * The API exposes no token log-probabilities, so this backend returns **no calibrated
    confidence**. Its result is marked `terminal: true`: the escalation accepts it without a
    threshold, and only where `Xeito.Policy` allows an off-box tier at all.
  * Cost: `usage.input_tokens` / `output_tokens` priced with `cfg[:price_per_mtok]`
    (`{input, output}` USD per million tokens; default the published `claude-opus-5` rates).
  """

  @behaviour Xeito.Backends

  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Type

  @default_model "claude-opus-5"
  @default_price {5.0, 25.0}

  @impl true
  def decide(type, input, cfg) do
    started = System.monotonic_time(:millisecond)
    model = Keyword.get(cfg, :model, @default_model)
    [system, user] = Prompt.messages(type, input)

    body = %{
      model: model,
      max_tokens: Keyword.get(cfg, :max_tokens, 4_096),
      system: system.content,
      messages: [%{role: "user", content: user.content}],
      output_config: %{
        effort: "low",
        format: %{type: "json_schema", schema: Prompt.json_schema(type)}
      },
      fallbacks: "default"
    }

    headers = [
      {"x-api-key", Keyword.fetch!(cfg, :api_key)},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta", "server-side-fallback-2026-07-01"}
    ]

    opts =
      [method: :post, url: "/v1/messages", json: body, headers: headers] ++
        [base_url: cfg[:url], receive_timeout: Keyword.get(cfg, :timeout, 120_000), retry: false] ++
        Keyword.take(cfg, [:plug])

    case Req.request(opts) do
      {:ok, %{status: 200, body: %{"stop_reason" => "refusal"} = resp}} ->
        {:error, {:refusal, resp["stop_details"]}}

      {:ok, %{status: 200, body: resp}} ->
        parse(type, resp, model, cfg, started)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse(type, resp, model, cfg, started) do
    text = for %{"type" => "text", "text" => t} <- resp["content"] || [], into: "", do: t

    with {:ok, %{"value" => raw}} <- JSON.decode(text),
         {:ok, value} <- Type.cast(type, raw) do
      {:ok,
       %{
         value: value,
         probabilities: %{},
         confidence: nil,
         terminal: true,
         model: resp["model"] || model,
         latency_ms: System.monotonic_time(:millisecond) - started,
         cost: cost(resp["usage"] || %{}, cfg)
       }}
    else
      _ -> {:error, {:unparseable, text}}
    end
  end

  @doc false
  def cost(usage, cfg) do
    {input_price, output_price} = Keyword.get(cfg, :price_per_mtok, @default_price)
    tokens_in = usage["input_tokens"] || 0
    tokens_out = usage["output_tokens"] || 0
    usd = (tokens_in * input_price + tokens_out * output_price) / 1_000_000
    %{tokens_in: tokens_in, tokens_out: tokens_out, usd: Float.round(usd, 6)}
  end
end
