defmodule Xeito.Chat.OpenRouter do
  @moduledoc """
  Streamed chat with tool calls on a hosted model through OpenRouter's chat completions API.

  `messages/1` converts Xeito's positional tool results to OpenAI's id pairing:

    * call ids are `call_<message>_<n>`, stable across sends so the prompt cache still matches;
    * every call gets an answer: a call without a result gets a note, and a result without its
      call becomes a user note (providers such as Anthropic refuse either).

  The request (`body/3`):

    * `provider`: `require_parameters`, `data_collection: "deny"`, `zdr` (default true), and
      `cfg[:providers]` as `only`.
    * `max_tokens` (default 8192), which also bounds the cost `Xeito.Allowance` plans for.
    * `cache_control` for `anthropic/` models.
    * `reasoning` and `temperature` only when the tier sets them; with `require_parameters`, a
      parameter no endpoint takes leaves no endpoint.

  The result has the shape of `Xeito.Chat.complete/4`'s, plus `usd`, `cached_tokens` and
  `served_by` (`openrouter:<model>@<provider>`).
  """

  alias Xeito.Backends
  alias Xeito.Backends.Failure
  alias Xeito.Chat.Message
  alias Xeito.Chat.OpenRouter.Stream

  @max_tokens 8192
  @no_result "(no result: the call was not run)"

  @doc "Runs one chat turn on the tier configured by `cfg`."
  @spec complete([Message.t()], [map()], keyword(), (String.t() -> any())) :: {:ok, Message.reply()} | {:error, term()}
  def complete(messages, tools, cfg, on_delta) do
    started = System.monotonic_time(:millisecond)

    opts =
      [
        method: :post,
        url: "/v1/chat/completions",
        json: body(messages, tools, cfg),
        headers: [{"x-openrouter-title", "Xeito"}],
        into: &into(&1, &2, on_delta)
      ] ++ Backends.req_options(Keyword.put_new(cfg, :timeout, 600_000))

    with {:ok, message} <- Failure.run(fn -> attempt(opts) end, Keyword.take(cfg, [:sleep, :attempts])),
         do: done(message, cfg, started)
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

    {:ok,
     Map.merge(message, %{
       model: model,
       served_by: message.served_by || "openrouter:" <> model,
       latency_ms: System.monotonic_time(:millisecond) - started,
       first_token_ms: nil
     })}
  end

  @doc false
  def body(messages, tools, cfg) do
    model = Keyword.fetch!(cfg, :model)

    %{
      model: model,
      messages: messages(messages),
      stream: true,
      usage: %{include: true},
      max_tokens: Keyword.get(cfg, :max_tokens, @max_tokens),
      provider: provider(cfg)
    }
    |> put_if(:tools, tools, tools != [])
    |> put_if(:cache_control, %{type: "ephemeral"}, String.starts_with?(model, "anthropic/"))
    |> put_if(:reasoning, %{effort: cfg[:reasoning]}, cfg[:reasoning] != nil)
    |> put_if(:temperature, cfg[:temperature], cfg[:temperature] != nil)
  end

  defp provider(cfg) do
    then(
      %{require_parameters: true, data_collection: "deny", zdr: Keyword.get(cfg, :zdr, true)},
      &if(cfg[:providers], do: Map.put(&1, :only, cfg[:providers]), else: &1)
    )
  end

  defp put_if(map, key, value, true), do: Map.put(map, key, value)
  defp put_if(map, _key, _value, false), do: map

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
