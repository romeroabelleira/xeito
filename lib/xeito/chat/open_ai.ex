defmodule Xeito.Chat.OpenAI do
  @moduledoc """
  Streamed chat with tool calls through OpenAI's chat completions API, as any compatible server speaks it.

  The wire format the OpenAI-speaking backends share (`Xeito.Backends.OpenAI`, `OpenRouter`,
  `Colibri`); each adds its own request fields to `body/3` and calls `request/4`.

  `messages/1` converts Xeito's positional tool results to OpenAI's id pairing:

    * call ids are `call_<message>_<n>`, stable across sends so a prompt cache still matches;
    * every call gets an answer: a call without a result gets a note, and a result without its
      call becomes a user note (providers such as Anthropic refuse either).

  The request (`body/3`): the model (`cfg[:model]`), the messages, `stream` with usage in the
  last chunk, `tools` when there are any, and only when set: `max_tokens`, `temperature`, and
  `response_format`, a strict JSON Schema from `format:`.

  `request/4` posts a body to `/v1/chat/completions` under `Xeito.Backends.Failure`'s retries;
  `wire` names the backend (`name:`, which labels `served_by` and errors) and its `headers:`.
  The result has the shape of `Xeito.Chat.complete/4`'s without the tier, plus `usd`,
  `cached_tokens` and `served_by` (`<name>:<model>@<provider>`).
  """

  alias Xeito.Backends
  alias Xeito.Backends.Failure
  alias Xeito.Chat.Message
  alias Xeito.Chat.OpenAI.Stream

  @no_result "(no result: the call was not run)"

  @doc "Runs one chat turn on the server configured by `cfg`."
  @spec complete([Message.t()], [map()], keyword(), (String.t() -> any())) :: {:ok, Message.reply()} | {:error, term()}
  def complete(messages, tools, cfg, on_delta), do: request(body(messages, tools, cfg), cfg, on_delta, name: :openai)

  @doc "The request body every OpenAI-compatible server takes."
  @spec body([Message.t()], [map()], keyword()) :: map()
  def body(messages, tools, cfg) do
    %{
      model: Keyword.fetch!(cfg, :model),
      messages: messages(messages),
      stream: true,
      stream_options: %{include_usage: true}
    }
    |> put_if(:tools, tools, tools != [])
    |> put_if(:max_tokens, cfg[:max_tokens], cfg[:max_tokens] != nil)
    |> put_if(:temperature, cfg[:temperature], cfg[:temperature] != nil)
    |> put_if(:response_format, response_format(cfg[:format]), cfg[:format] != nil)
  end

  @doc "A strict JSON Schema as `response_format`."
  @spec response_format(map() | nil) :: map()
  def response_format(schema), do: %{type: "json_schema", json_schema: %{name: "answer", strict: true, schema: schema}}

  @doc "`map` with `key` set when `set?`."
  @spec put_if(map(), atom(), term(), boolean()) :: map()
  def put_if(map, key, value, true), do: Map.put(map, key, value)
  def put_if(map, _key, _value, false), do: map

  @doc "Posts `body` as one streamed chat completion; `wire`: the backend's `name:` and `headers:`."
  @spec request(map(), keyword(), (String.t() -> any()), keyword()) :: {:ok, Message.reply()} | {:error, term()}
  def request(body, cfg, on_delta, wire) do
    started = System.monotonic_time(:millisecond)
    name = Keyword.fetch!(wire, :name)

    opts =
      [
        method: :post,
        url: "/v1/chat/completions",
        json: body,
        headers: Keyword.get(wire, :headers, []),
        into: &into(&1, &2, name, on_delta)
      ] ++ Backends.req_options(Keyword.put_new(cfg, :timeout, 600_000))

    with {:ok, message} <- Failure.run(fn -> attempt(opts) end, Keyword.take(cfg, [:sleep, :attempts, :on_retry])),
         do: done(message, name, body.model, started)
  end

  # One request. A failure after output was streamed is final: a retry would repeat it.
  defp attempt(opts) do
    Process.put(:xeito_streamed, false)

    case Req.request(opts) do
      {:ok, %{status: 200} = resp} -> resp.private.stream |> Stream.finish() |> answer()
      {:ok, %{status: status} = resp} -> {:failed, status, Map.get(resp.private, :raw, ""), headers(resp)}
      {:error, reason} -> if Process.get(:xeito_streamed), do: {:final, reason}, else: {:error, reason}
    end
  after
    Process.delete(:xeito_streamed)
  end

  # A stream that stops for length before writing anything ran out of window, not of answer.
  defp answer({:ok, %{finish_reason: "length", content: "", tool_calls: []}}),
    do: {:final, Failure.overflow("the model stopped for length before writing anything")}

  defp answer({:ok, message}), do: {:ok, message}
  defp answer(error), do: {:final, elem(error, 1)}

  defp headers(resp), do: for({name, values} <- resp.headers, value <- List.wrap(values), do: {name, value})

  defp into({:data, data}, {req, %{status: 200} = resp}, name, on_delta) do
    Process.put(:xeito_streamed, true)
    stream = Map.get(resp.private, :stream, Stream.new(name))
    {:cont, {req, Req.Response.put_private(resp, :stream, Stream.feed(stream, data, on_delta))}}
  end

  # An error's body is kept as it came, for the message.
  defp into({:data, data}, {req, resp}, _name, _on_delta),
    do: {:cont, {req, Req.Response.put_private(resp, :raw, Map.get(resp.private, :raw, "") <> data)}}

  defp done(message, name, model, started) do
    {:ok,
     Map.merge(message, %{
       model: model,
       served_by: message.served_by || "#{name}:#{model}",
       latency_ms: System.monotonic_time(:millisecond) - started,
       first_token_ms: nil
     })}
  end

  @doc "Xeito's messages in OpenAI's form: tool calls and their results paired by id."
  @spec messages([Message.t()]) :: [map()]
  def messages(messages) do
    {out, pending} =
      messages
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {m, i}, {out, pending} -> message(m, i, out, pending) end)

    Enum.reverse(answer_all(out, pending))
  end

  # A result answers the oldest call still waiting; without one, it is a note.
  defp message(%{role: "tool"} = m, _i, out, [id | pending]),
    do: {[%{role: "tool", tool_call_id: id, content: m.content} | out], pending}

  defp message(%{role: "tool"} = m, _i, out, []),
    do: {[%{role: "user", content: "[#{m[:tool_name]} result]\n" <> m.content} | out], []}

  defp message(%{role: "assistant", tool_calls: [_ | _] = calls} = m, i, out, pending) do
    ids = Enum.map(1..length(calls), &"call_#{i}_#{&1}")

    calls =
      Enum.zip_with(ids, calls, fn id, %{function: f} ->
        %{id: id, type: "function", function: %{name: f.name, arguments: JSON.encode!(f.arguments)}}
      end)

    content = if m.content in [nil, ""], do: nil, else: m.content
    {[%{role: "assistant", content: content, tool_calls: calls} | answer_all(out, pending)], ids}
  end

  defp message(m, _i, out, pending), do: {[Map.take(m, [:role, :content]) | answer_all(out, pending)], []}

  defp answer_all(out, pending),
    do: Enum.reduce(pending, out, &[%{role: "tool", tool_call_id: &1, content: @no_result} | &2])
end
