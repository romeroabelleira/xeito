defmodule Xeito.Backends.OpenAI do
  @moduledoc """
  OpenAI-compatible backend: decisions and chat on any server that speaks OpenAI's chat completions.

  A tier needs a `url` (the server's root, before `/v1`) and a `model`; `api_key` is optional.

  Decisions (`decide/3`, `body/3`):
    * the decision's JSON Schema as `response_format` (`strict: true`), temperature 0
    * `logprobs` with `top_logprobs` (at most 20), unless `logprobs: false`: a server that
      refuses them needs that setting
    * confidence from the value's first-token `top_logprobs`, as `Xeito.Backends.Ollama.probabilities/3`;
      a reply without logprobs is a `terminal: true` result without confidence; a refusal is an error
    * cost: token counts, and `usage.cost` (USD) where the server reports one

  `ask/4` runs a decision body for the backends that share this API (`Xeito.Backends.OpenRouter`):
  `wire` gives the backend's `name:`, which labels the model (`<name>:<model>@<provider>`) and
  errors, and its `headers:`.

  Chat (`chat/4`) is `Xeito.Chat.OpenAI`'s. `probe/2` reads `GET /v1/models`: up, and the models
  the server lists. No cost is known (`Xeito.Backends.spend/1` is `:none`), so chat on an
  off-box tier is refused.
  """

  @behaviour Xeito.Backends

  alias Xeito.Backends
  alias Xeito.Backends.Failure
  alias Xeito.Backends.Ollama
  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Type

  @impl true
  def decide(type, input, cfg), do: ask(type, body(type, input, cfg), cfg, name: :openai)

  @impl true
  def chat(messages, tools, cfg, on_delta), do: Xeito.Chat.OpenAI.complete(messages, tools, cfg, on_delta)

  @impl true
  def probe(cfg, opts) do
    case Backends.get(cfg, "/v1/models", Keyword.fetch!(opts, :timeout)) do
      {:ok, %{"data" => models}} -> %{up: true, loaded: Enum.map(models, &listed/1)}
      _ -> %{up: false, loaded: []}
    end
  end

  defp listed(model), do: %{name: model["id"], context: model["context_length"]}

  @doc "Runs a decision request `body`; `wire`: the backend's `name:` and `headers:`."
  @spec ask(Type.t(), map(), keyword(), keyword()) :: {:ok, Backends.result()} | {:error, term()}
  def ask(type, body, cfg, wire) do
    started = System.monotonic_time(:millisecond)
    name = Keyword.fetch!(wire, :name)

    opts =
      [method: :post, url: "/v1/chat/completions", json: body, headers: Keyword.get(wire, :headers, [])] ++
        Backends.req_options(Keyword.put_new(cfg, :timeout, 60_000))

    case Failure.run(fn -> request(opts) end, Keyword.take(cfg, [:sleep, :attempts])) do
      {:ok, %{"choices" => [choice | _]} = resp} -> parse(type, choice, resp, {name, body.model}, started)
      {:ok, %{"error" => error}} -> {:error, {name, error}}
      {:error, reason} -> {:error, reason}
    end
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

  @doc "The decision request every OpenAI-compatible server takes."
  @spec body(Type.t(), map(), keyword()) :: map()
  def body(type, input, cfg) do
    Map.merge(
      %{
        model: Keyword.fetch!(cfg, :model),
        messages: Prompt.messages(type, input),
        response_format: %{
          type: "json_schema",
          json_schema: %{name: type.name, strict: true, schema: Prompt.json_schema(type)}
        },
        temperature: 0,
        max_tokens: Keyword.get(cfg, :max_tokens, 64)
      },
      logprobs(cfg)
    )
  end

  # Without logprobs the answer is terminal.
  defp logprobs(cfg) do
    if Keyword.get(cfg, :logprobs, true),
      do: %{logprobs: true, top_logprobs: min(Keyword.get(cfg, :top_logprobs, 20), 20)},
      else: %{}
  end

  defp parse(_type, %{"message" => %{"refusal" => refusal}}, _resp, _label, _started)
       when is_binary(refusal) and refusal != "", do: {:error, {:refusal, refusal}}

  defp parse(type, choice, resp, {name, model}, started) do
    content = get_in(choice, ["message", "content"]) || ""
    {served_by, cost} = served_and_cost(resp, name, model)

    case get_in(choice, ["logprobs", "content"]) do
      [_ | _] = logprobs ->
        type |> probabilities(content, logprobs) |> result(type, served_by, started, cost)

      _ ->
        terminal(type, content, served_by, started, cost)
    end
  end

  defp served_and_cost(resp, name, model),
    do: {served_by(name, resp["model"] || model, resp["provider"]), cost(resp["usage"] || %{})}

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

  defp served_by(name, model, nil), do: "#{name}:#{model}"
  defp served_by(name, model, provider), do: "#{name}:#{model}@#{provider}"

  @doc false
  def cost(usage) do
    %{
      tokens_in: usage["prompt_tokens"] || 0,
      tokens_out: usage["completion_tokens"] || 0,
      usd: usage["cost"] || 0.0
    }
  end
end
