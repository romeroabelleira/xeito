defmodule Xeito.Chat.Anthropic do
  @moduledoc """
  Streamed chat with tool calls on Claude through the Claude API's `POST /v1/messages`.

  `messages/1` converts Xeito's conversation (`Xeito.Chat.Message`) to the API's form:

    * system messages become the request's `system`;
    * call ids are `toolu_<message>_<n>`, stable across sends so the prompt cache still matches, and
      the results follow as `tool_result` blocks; a call without a result gets a note, and a result
      without its call becomes a user note;
    * neighbouring messages of one role are merged into one, and an empty assistant message is dropped.

  The request (`body/3`):

    * `max_tokens` (default 8192), which also bounds the cost `Xeito.Allowance` plans for;
    * `cache_control` on the request, so the conversation's prefix is cached;
    * `output_config.effort` from the tier's `reasoning`; thinking is the model's own (adaptive);
    * `output_config.format`, a JSON Schema, when `format:` sets one;
    * `fallbacks: "default"` on the models that take it (`Xeito.Backends.Anthropic.fallbacks?/1`);
    * no temperature: the API version Xeito speaks takes none.

  The result has the shape of `Xeito.Chat.complete/4`'s, plus `usd` (`Xeito.Backends.Anthropic.cost/2`),
  `cached_tokens` and `served_by` (`anthropic:<model>`, the fallback model when one took over).
  A refusal that comes back despite the fallback is an error.
  """

  alias Xeito.Backends.Anthropic
  alias Xeito.Backends.Failure
  alias Xeito.Chat.Anthropic.Stream
  alias Xeito.Chat.Message

  @max_tokens 8192
  @no_result "(no result: the call was not run)"
  @no_output "(no output)"

  @doc "Runs one chat turn on the tier configured by `cfg`."
  @spec complete([Message.t()], [map()], keyword(), (String.t() -> any())) :: {:ok, Message.reply()} | {:error, term()}
  def complete(messages, tools, cfg, on_delta) do
    started = System.monotonic_time(:millisecond)

    opts =
      [method: :post, url: "/v1/messages", json: body(messages, tools, cfg), into: &into(&1, &2, on_delta)] ++
        Anthropic.req_options(cfg, 600_000)

    with {:ok, message} <- Failure.run(fn -> attempt(opts) end, Keyword.take(cfg, [:sleep, :attempts, :on_retry])),
         do: {:ok, done(message, cfg, started)}
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

  defp answer({:ok, %{finish_reason: "refusal"}}), do: {:final, {:refusal, "the model declined the request"}}

  # A stream that stops for length before writing anything ran out of window, not of answer.
  defp answer({:ok, %{finish_reason: "max_tokens", content: "", tool_calls: []}}),
    do: {:final, Failure.overflow("the model stopped for length before writing anything")}

  defp answer({:ok, message}), do: {:ok, message}
  defp answer({:error, reason}), do: {:final, reason}

  defp headers(resp), do: for({name, values} <- resp.headers, value <- List.wrap(values), do: {name, value})

  defp into({:data, data}, {req, %{status: 200} = resp}, on_delta) do
    Process.put(:xeito_streamed, true)
    stream = Map.get(resp.private, :stream, Stream.new())
    {:cont, {req, Req.Response.put_private(resp, :stream, Stream.feed(stream, data, on_delta))}}
  end

  # An error's body is kept as it came, for the message.
  defp into({:data, data}, {req, resp}, _on_delta),
    do: {:cont, {req, Req.Response.put_private(resp, :raw, Map.get(resp.private, :raw, "") <> data)}}

  defp done(message, cfg, started) do
    model = Keyword.fetch!(cfg, :model)

    Map.merge(Anthropic.usage(Anthropic.price(model), message.usage), %{
      content: message.content,
      tool_calls: message.tool_calls,
      model: model,
      served_by: "anthropic:" <> (message.model || model),
      finish_reason: message.finish_reason,
      latency_ms: System.monotonic_time(:millisecond) - started,
      first_token_ms: nil
    })
  end

  @doc false
  def body(messages, tools, cfg) do
    model = Keyword.fetch!(cfg, :model)
    {system, messages} = messages(messages)
    output = output_config(cfg)

    %{
      model: model,
      messages: messages,
      stream: true,
      max_tokens: Keyword.get(cfg, :max_tokens, @max_tokens),
      cache_control: %{type: "ephemeral"}
    }
    |> put_if(:system, system, system != "")
    |> put_if(:tools, tools(tools), tools != [])
    |> put_if(:output_config, output, output != %{})
    |> put_if(:fallbacks, "default", Anthropic.fallbacks?(model))
  end

  defp output_config(cfg) do
    %{}
    |> put_if(:effort, cfg[:reasoning], cfg[:reasoning] != nil)
    |> put_if(:format, %{type: "json_schema", schema: cfg[:format]}, cfg[:format] != nil)
  end

  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp put_if(map, _key, _value, false), do: map

  @doc "OpenAI-style function specs (`Xeito.Tools.specs/0`) as the API's tools."
  @spec tools([map()]) :: [map()]
  def tools(specs),
    do: for(%{function: f} <- specs, do: %{name: f.name, description: f.description, input_schema: f.parameters})

  @doc "Xeito's messages in the API's form: the system text, and the conversation with calls and results paired by id."
  @spec messages([Message.t()]) :: {String.t(), [map()]}
  def messages(messages) do
    {system, rest} = Enum.split_with(messages, &(&1.role == "system"))

    {out, pending} =
      rest
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {m, i}, {out, pending} -> message(m, i, out, pending) end)

    {Enum.map_join(system, "\n\n", & &1.content), out |> answer_all(pending) |> Enum.reverse() |> merge([])}
  end

  # A result answers the oldest call still waiting; without one, it is a note.
  defp message(%{role: "tool"} = m, _i, out, [id | pending]),
    do: {[user([%{type: "tool_result", tool_use_id: id, content: text_or(m.content, @no_output)}]) | out], pending}

  defp message(%{role: "tool"} = m, _i, out, []),
    do: {[user([%{type: "text", text: "[#{m[:tool_name]} result]\n" <> m.content}]) | out], []}

  defp message(%{role: "assistant", tool_calls: [_ | _] = calls} = m, i, out, pending) do
    ids = Enum.map(1..length(calls), &"toolu_#{i}_#{&1}")

    uses =
      Enum.zip_with(ids, calls, fn id, %{function: f} -> %{type: "tool_use", id: id, name: f.name, input: f.arguments} end)

    {[%{role: "assistant", content: text_blocks(m.content) ++ uses} | answer_all(out, pending)], ids}
  end

  defp message(%{content: content}, _i, out, pending) when content in [nil, ""], do: {answer_all(out, pending), []}

  defp message(m, _i, out, pending),
    do: {[%{role: m.role, content: text_blocks(m.content)} | answer_all(out, pending)], []}

  defp user(blocks), do: %{role: "user", content: blocks}

  defp text_blocks(text) when text in [nil, ""], do: []
  defp text_blocks(text), do: [%{type: "text", text: text}]

  defp text_or(text, fallback) when text in [nil, ""], do: fallback
  defp text_or(text, _fallback), do: text

  defp answer_all(out, pending),
    do: Enum.reduce(pending, out, &[user([%{type: "tool_result", tool_use_id: &1, content: @no_result}]) | &2])

  # Neighbouring messages of one role become one, as the API wants turns to alternate.
  defp merge([%{role: role, content: a}, %{role: role, content: b} | rest], acc),
    do: merge([%{role: role, content: a ++ b} | rest], acc)

  defp merge([m | rest], acc), do: merge(rest, [m | acc])
  defp merge([], acc), do: Enum.reverse(acc)
end
