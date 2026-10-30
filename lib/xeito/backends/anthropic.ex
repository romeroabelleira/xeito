defmodule Xeito.Backends.Anthropic do
  @moduledoc """
  Claude API backend: decisions on Claude through `POST /v1/messages`, for a remote tier that speaks
  to Anthropic directly rather than through OpenRouter.

  Request: the decision's JSON Schema as `output_config.format`, effort `low`, the model's own
  (adaptive) thinking, and `fallbacks: "default"` where the model takes it, so a request a safety
  classifier declines runs again on Anthropic's fallback model server-side.

  Result: the API returns no logprobs, so the answer is `terminal: true` without confidence; a
  refusal that comes back anyway is an error. Cost is computed from `price/1`, the published list
  prices (USD per token; the API reports none), as `cost/2`; `model` is `anthropic:<model>`.

  `headers/1` and `version/0` are what every request to the API carries; `Xeito.Chat.Anthropic`
  uses them too. `Xeito.Policy` gates every tier that uses this backend, as every off-box tier.
  """

  @behaviour Xeito.Backends

  alias Xeito.Backends
  alias Xeito.Backends.Failure
  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Type

  @version "2026-10-21"
  @fallback_beta "server-side-fallback-2026-07-01"

  # USD per million tokens: input, output, cache read (a cache write costs 1.25 × input); the
  # window and the longest answer. Published list prices, 2026-10.
  @prices %{
    "claude-fable-5-1" => {10, 50, 0.25, 1_000_000, 128_000},
    "claude-fable-5" => {10, 50, 0.25, 1_000_000, 128_000},
    "claude-opus-5-5" => {4, 20, 0.20, 1_000_000, 128_000},
    "claude-opus-5" => {5, 25, 0.50, 1_000_000, 128_000},
    "claude-opus-4-8" => {5, 25, 0.50, 1_000_000, 128_000},
    "claude-opus-4-7" => {5, 25, 0.50, 1_000_000, 128_000},
    "claude-opus-4-6" => {5, 25, 0.50, 1_000_000, 128_000},
    "claude-sonnet-5-5" => {2, 10, 0.20, 1_000_000, 128_000},
    "claude-sonnet-5" => {2, 10, 0.20, 1_000_000, 128_000},
    "claude-sonnet-4-6" => {3, 15, 0.30, 1_000_000, 128_000},
    "claude-haiku-5-5" => {0.10, 0.50, 0.01, 1_000_000, 128_000},
    "claude-haiku-4-5" => {1, 5, 0.10, 200_000, 64_000}
  }
  # Haiku 5.5 charges five times as much for a prompt past 100k tokens.
  @tiers %{"claude-haiku-5-5" => [%{from: 100_000, prompt: 0.50 / 1_000_000, completion: 2.50 / 1_000_000}]}

  # Models whose safety classifiers may decline a request, and that take `fallbacks: "default"`.
  @fallbacks ~w(claude-fable-5-1 claude-fable-5 claude-opus-5-5 claude-opus-5 claude-sonnet-5-5)

  @typedoc "A model's price per token, in the shape `Xeito.Allowance.price/1` gives for OpenRouter models."
  @type price :: %{
          prompt: float(),
          completion: float(),
          cache_read: float(),
          context: pos_integer(),
          output: pos_integer(),
          tiers: [%{from: pos_integer(), prompt: float(), completion: float()}]
        }

  @impl true
  def decide(type, input, cfg) do
    started = System.monotonic_time(:millisecond)
    model = Keyword.fetch!(cfg, :model)
    opts = [method: :post, url: "/v1/messages", json: body(type, input, cfg)] ++ req_options(cfg, 60_000)

    case Failure.run(fn -> request(opts) end, Keyword.take(cfg, [:sleep, :attempts])) do
      {:ok, %{"stop_reason" => "refusal"} = resp} ->
        {:error, {:refusal, get_in(resp, ["stop_details", "explanation"]) || "refused"}}

      {:ok, resp} ->
        parse(type, resp, model, started)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The API version every request names."
  @spec version() :: String.t()
  def version, do: @version

  @doc "The request headers for `model`: the key, the API version, and the fallback beta where the model takes it."
  @spec headers(keyword()) :: [{String.t(), String.t()}]
  def headers(cfg) do
    [{"x-api-key", Keyword.fetch!(cfg, :api_key)}, {"anthropic-version", @version}] ++
      if(fallbacks?(Keyword.fetch!(cfg, :model)), do: [{"anthropic-beta", @fallback_beta}], else: [])
  end

  @doc "Req options for the API: the headers, the base URL, no retries, and `timeout` ms unless the tier sets one."
  @spec req_options(keyword(), pos_integer()) :: keyword()
  def req_options(cfg, timeout) do
    [headers: headers(cfg)] ++
      (cfg |> Keyword.delete(:api_key) |> Keyword.put_new(:timeout, timeout) |> Backends.req_options())
  end

  @doc "Whether the model takes `fallbacks: \"default\"`."
  @spec fallbacks?(String.t()) :: boolean()
  def fallbacks?(model), do: model in @fallbacks

  @doc "A model's price per token, window and longest answer; `nil` for a model not in the table."
  @spec price(String.t()) :: price() | nil
  def price(model) do
    case @prices[model] do
      nil ->
        nil

      {input, output, cache_read, context, longest} ->
        %{
          prompt: input / 1_000_000,
          completion: output / 1_000_000,
          cache_read: cache_read / 1_000_000,
          context: context,
          output: longest,
          tiers: Map.get(@tiers, model, [])
        }
    end
  end

  @doc """
  What a call cost in USD, from the API's usage (`input_tokens`: the uncached prompt; cache reads and
  writes; `output_tokens`), at the model's price; `0.0` for a model without one.
  """
  @spec cost(price() | nil, map()) :: float()
  def cost(nil, _usage), do: 0.0

  def cost(price, usage) do
    %{input: input, read: read, written: written, output: output} = counts(usage)
    rate = price |> Map.get(:tiers, []) |> Enum.filter(&(&1.from <= input + read + written)) |> List.last(price)
    input * rate.prompt + read * price.cache_read + written * rate.prompt * 1.25 + output * rate.completion
  end

  @doc """
  What a call's usage amounts to: `usd` at the model's price (`cost/2`), the prompt's tokens (cache
  reads and writes included), the answer's, and the tokens read from the cache.
  """
  @spec usage(price() | nil, map()) :: %{
          usd: float(),
          tokens_in: non_neg_integer(),
          tokens_out: non_neg_integer(),
          cached_tokens: non_neg_integer()
        }
  def usage(price, usage) do
    %{input: input, read: read, written: written, output: output} = counts(usage)
    %{usd: cost(price, usage), tokens_in: input + read + written, tokens_out: output, cached_tokens: read}
  end

  defp counts(usage) do
    %{
      input: usage["input_tokens"] || 0,
      read: usage["cache_read_input_tokens"] || 0,
      written: usage["cache_creation_input_tokens"] || 0,
      output: usage["output_tokens"] || 0
    }
  end

  @doc false
  def body(type, input, cfg) do
    [%{content: system}, %{content: user}] = Prompt.messages(type, input)
    model = Keyword.fetch!(cfg, :model)

    then(
      %{
        model: model,
        max_tokens: Keyword.get(cfg, :max_tokens, 1024),
        system: system,
        messages: [%{role: "user", content: user}],
        output_config: %{effort: "low", format: %{type: "json_schema", schema: Prompt.json_schema(type)}}
      },
      &if(fallbacks?(model), do: Map.put(&1, :fallbacks, "default"), else: &1)
    )
  end

  # One request: its body on success, else what `Xeito.Backends.Failure` needs to judge it.
  defp request(opts) do
    case Req.request(opts) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body} = resp} ->
        {:failed, status, if(is_binary(body), do: body, else: JSON.encode!(body)),
         for({name, values} <- resp.headers, value <- List.wrap(values), do: {name, value})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse(type, resp, model, started) do
    text = text(resp["content"])

    with {:ok, %{"value" => raw}} <- JSON.decode(text),
         {:ok, value} <- Type.cast(type, raw) do
      {:ok,
       %{
         value: value,
         probabilities: %{},
         confidence: nil,
         terminal: true,
         model: "anthropic:" <> Map.get(resp, "model", model),
         latency_ms: System.monotonic_time(:millisecond) - started,
         cost: model |> price() |> usage(resp["usage"] || %{}) |> Map.take([:usd, :tokens_in, :tokens_out])
       }}
    else
      _ -> {:error, {:unparseable, text}}
    end
  end

  # The first text block; structured output puts the JSON there.
  defp text(content), do: content |> List.wrap() |> Enum.find_value("", &(&1["type"] == "text" and &1["text"]))
end
