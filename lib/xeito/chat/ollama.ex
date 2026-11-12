defmodule Xeito.Chat.Ollama do
  @moduledoc """
  Streamed chat with tool calls on a local model through Ollama's `/api/chat`.

    * model: `cfg[:chat_model]`, else the tier's `cfg[:model]`
    * `think` is off unless `cfg[:think]`; `cfg[:format]`, a JSON Schema, constrains the answer
    * `num_ctx` from `cfg[:context]` and `keep_alive` go with every request, so the model is not reloaded
    * the stream is NDJSON; each text chunk goes to `on_delta`

  The result has the shape of `Xeito.Chat.complete/4`'s, without the tier.
  """

  alias Xeito.Backends
  alias Xeito.Chat.Message

  @doc "Runs one chat turn on the Ollama service configured by `cfg`."
  @spec complete([Message.t()], [map()], keyword(), (String.t() -> any())) :: {:ok, Message.reply()} | {:error, term()}
  def complete(messages, tools, cfg, on_delta) do
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
