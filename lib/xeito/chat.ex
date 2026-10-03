defmodule Xeito.Chat do
  @moduledoc """
  The chat model client used by the free chat machine and delegated sub-tasks: Ollama
  `/api/chat` with native tool calling, streamed.

  The model is the large tier's (`config :xeito, :tiers, large: [...]`), or `cfg[:chat_model]`
  when a different chat model is configured. Calls go through the large tier's capacity queue,
  so a streaming answer and a large-tier decision never compete for the GPU.

  Each streamed chunk of content is passed to `on_delta` (the effect runner forwards it to
  `Xeito.Events`), and the call returns the complete assistant message:

      {:ok, %{content: "...", tool_calls: [%{name: "bash", arguments: %{...}}],
              model: "...", tokens_in: 812, tokens_out: 64, latency_ms: 2140,
              first_token_ms: 410}}

  Thinking is off by default (`cfg[:think]`), because the harness wants short turns; the
  statechart, not a long hidden monologue, carries the plan.
  """

  alias Xeito.Tiers
  alias Xeito.Tiers.Queue

  @type message :: %{required(:role) => String.t(), optional(atom()) => term()}

  @doc "Runs one chat turn. `tools` are OpenAI-style function specs (see `Xeito.Tools.specs/0`)."
  @spec complete([message()], [map()], keyword(), (String.t() -> any())) ::
          {:ok, map()} | {:error, term()}
  def complete(messages, tools, overrides \\ [], on_delta \\ fn _ -> :ok end) do
    case Tiers.config(:large, overrides) do
      nil -> {:error, :chat_model_unavailable}
      cfg -> Queue.run(:large, fn -> request(messages, tools, cfg, on_delta) end)
    end
  end

  defp request(messages, tools, cfg, on_delta) do
    started = System.monotonic_time(:millisecond)
    model = Keyword.get(cfg, :chat_model, Keyword.fetch!(cfg, :model))

    body = %{
      model: model,
      # Messages may carry Xeito's own bookkeeping (`ref`, `about`); Ollama gets its fields only.
      messages: Enum.map(messages, &Map.take(&1, [:role, :content, :tool_calls, :tool_name])),
      tools: tools,
      stream: true,
      think: Keyword.get(cfg, :think, false),
      options: Tiers.context_options(cfg, %{temperature: Keyword.get(cfg, :temperature, 0.2)}),
      keep_alive: Keyword.get(cfg, :keep_alive, "10m")
    }

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
        Tiers.req_options(Keyword.put_new(cfg, :timeout, 600_000))

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

  # A message's text and tool calls.
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

  # Time to the first chunk that carries text or a tool call (what the user starts to see).
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
