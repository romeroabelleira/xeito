defmodule Xeito.Chat do
  @moduledoc """
  Streaming chat-model client with native tool calling, used by the chat machine and delegated sub-tasks.

    * tier (`tier/1`): option `tier:`, else `config :xeito, :chat_tier`, else `:local`
    * `:ollama` backend: Ollama `/api/chat`, model `cfg[:chat_model]` or the tier's
    * `:openrouter` backend: `Xeito.Chat.OpenRouter`; each call must pass `Xeito.Allowance.verdict/1`
      (run budget `max_usd:`, key allowance) and its cost is charged to `run:` and the key
    * calls go through the tier's capacity queue (`Xeito.Tiers.Queue`)
    * thinking is off unless `cfg[:think]`; `cfg[:format]`, a JSON Schema, constrains the answer
    * the reply says its `tier`

  Each streamed text chunk goes to `on_delta`; the call returns the complete message:

      {:ok, %{content: "...", tool_calls: [%{name: "bash", arguments: %{...}}],
              model: "...", tier: :local, tokens_in: 812, tokens_out: 64, latency_ms: 2140,
              first_token_ms: 410}}
  """

  alias Xeito.Allowance
  alias Xeito.Backends
  alias Xeito.Budget
  alias Xeito.Chat.Message
  alias Xeito.Chat.OpenRouter
  alias Xeito.Chat.Window
  alias Xeito.Policy
  alias Xeito.Tiers
  alias Xeito.Tiers.Queue

  @type message :: Message.t()

  @doc "Runs one chat turn. `tools` are OpenAI-style function specs (see `Xeito.Tools.specs/0`)."
  @spec complete([Message.t()], [map()], keyword(), (String.t() -> any())) ::
          {:ok, Message.reply()} | {:error, term()}
  def complete(messages, tools, overrides \\ [], on_delta \\ fn _ -> :ok end) do
    tier = tier(overrides)

    case Tiers.config(tier, Keyword.delete(overrides, :tier)) do
      nil -> {:error, :chat_model_unavailable}
      cfg -> chat(Tiers.backend(tier, cfg), tier, {messages, tools}, cfg, on_delta)
    end
  end

  @doc "The chat tier: the session's choice (`tier:`), else the configured one, else `:local`."
  @spec tier(keyword()) :: atom()
  def tier(overrides), do: Keyword.get_lazy(overrides, :tier, fn -> Application.get_env(:xeito, :chat_tier, :local) end)

  defp chat(:ollama, tier, {messages, tools}, cfg, on_delta) do
    with {:ok, message} <- Queue.run(tier, fn -> request(messages, tools, cfg, on_delta) end),
         do: {:ok, Map.put(message, :tier, tier)}
  end

  defp chat(:openrouter, tier, {messages, tools}, cfg, on_delta) do
    price = Allowance.model_price(cfg)
    cfg = Keyword.put_new(cfg, :max_tokens, answer_limit(price))

    with :ok <- plan(messages, tools, cfg, price) do
      tier
      |> Queue.run(fn -> OpenRouter.complete(messages, tools, cfg, on_delta) end)
      |> charge(tier, cfg)
    end
  end

  defp chat(backend, _tier, _request, _cfg, _on_delta), do: {:error, {:no_chat_backend, backend}}

  # The longest answer asked for: 8192 tokens, or less where the model allows less.
  defp answer_limit(%{output: output}) when is_integer(output), do: min(output, 8192)
  defp answer_limit(_price), do: 8192

  defp plan(messages, tools, cfg, price) do
    tokens = Window.estimate(messages, Window.default_chars_per_token()) + div(byte_size(JSON.encode!(tools)), 3)

    Allowance.verdict(%{
      run_spent: if(cfg[:run], do: Budget.get(cfg[:run], :usd), else: 0),
      run_max: Keyword.get_lazy(cfg, :max_usd, fn -> Policy.effective().max_usd_per_run end),
      left: Allowance.remaining(cfg),
      worst: Allowance.worst_case(price, tokens, cfg[:max_tokens])
    })
  end

  defp charge({:ok, message}, tier, cfg) do
    Allowance.spent(cfg, message.usd)
    if cfg[:run], do: Budget.add(cfg[:run], :usd, message.usd)
    {:ok, Map.put(message, :tier, tier)}
  end

  defp charge(error, _tier, _cfg), do: error

  defp request(messages, tools, cfg, on_delta) do
    started = System.monotonic_time(:millisecond)
    model = Keyword.get(cfg, :chat_model, Keyword.fetch!(cfg, :model))

    body = body(model, messages, tools, cfg)

    Process.put(:xeito_chat, %{
      buffer: "",
      content: [],
      tool_calls: [],
      final: %{},
      started: started,
      first_ms: nil
    })

    opts =
      [method: :post, url: "/api/chat", json: body, into: &into(&1, &2, on_delta)] ++
        Backends.req_options(Keyword.put_new(cfg, :timeout, 600_000))

    case Req.request(opts) do
      {:ok, %{status: 200}} ->
        acc = flush(on_delta)

        {:ok,
         %{
           content: acc.content |> Enum.reverse() |> IO.iodata_to_binary(),
           tool_calls: Enum.reverse(acc.tool_calls),
           model: model,
           tokens_in: acc.final["prompt_eval_count"] || 0,
           tokens_out: acc.final["eval_count"] || 0,
           latency_ms: System.monotonic_time(:millisecond) - started,
           first_token_ms: acc.first_ms
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  after
    Process.delete(:xeito_chat)
  end

  defp body(model, messages, tools, cfg) do
    body = %{
      model: model,
      # Messages may carry Xeito's own bookkeeping (`ref`, `about`); Ollama gets its fields only.
      messages: Enum.map(messages, &Map.take(&1, [:role, :content, :tool_calls, :tool_name])),
      tools: tools,
      stream: true,
      think: Keyword.get(cfg, :think, false),
      options: Backends.context_options(cfg, %{temperature: Keyword.get(cfg, :temperature, 0.2)}),
      keep_alive: Keyword.get(cfg, :keep_alive, "10m")
    }

    if cfg[:format], do: Map.put(body, :format, cfg[:format]), else: body
  end

  # NDJSON: one JSON object per line; chunks can split lines.
  defp into({:data, data}, {req, resp}, on_delta) do
    acc = Process.get(:xeito_chat)
    lines = String.split(acc.buffer <> data, "\n")
    {complete, [rest]} = Enum.split(lines, -1)
    acc = Enum.reduce(complete, %{acc | buffer: rest}, &line(&1, &2, on_delta))
    Process.put(:xeito_chat, acc)
    {:cont, {req, resp}}
  end

  defp flush(on_delta) do
    acc = Process.get(:xeito_chat)
    line(acc.buffer, %{acc | buffer: ""}, on_delta)
  end

  defp line(line, acc, on_delta) do
    case line |> String.trim() |> decode() do
      nil ->
        acc

      %{"error" => error} ->
        raise "chat model error: #{inspect(error)}"

      chunk ->
        chunk(chunk, acc, on_delta)
    end
  end

  defp chunk(chunk, acc, on_delta) do
    {text, calls} = parts(chunk["message"] || %{})
    if text != "", do: on_delta.(text)

    %{
      acc
      | content: add_text(acc.content, text),
        tool_calls: Enum.reverse(calls, acc.tool_calls),
        final: final(chunk, acc.final),
        first_ms: acc.first_ms || first_ms(acc.started, text, calls)
    }
  end

  defp parts(message) do
    calls =
      for %{"function" => f} <- message["tool_calls"] || [], do: %{name: f["name"], arguments: arguments(f["arguments"])}

    {message["content"] || "", calls}
  end

  defp add_text(content, ""), do: content
  defp add_text(content, text), do: [text | content]

  # The last chunk carries the token counts.
  defp final(%{"done" => true} = chunk, _final), do: chunk
  defp final(_chunk, final), do: final

  # Time to the first chunk that carries text or a tool call.
  defp first_ms(_started, "", []), do: nil
  defp first_ms(started, _text, _calls), do: System.monotonic_time(:millisecond) - started

  defp decode(""), do: nil

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp arguments(args) when is_map(args), do: args

  defp arguments(args) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"_raw" => args}
    end
  end

  defp arguments(_), do: %{}
end
