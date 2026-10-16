defmodule Xeito.Chat.OpenRouter do
  @moduledoc """
  Chat on a hosted model through OpenRouter: OpenAI's `POST /api/v1/chat/completions`, streamed,
  with tool calls. `Xeito.Chat` uses it when the chat tier's backend is `:openrouter`.

  Xeito keeps its conversation in Ollama's form, where a tool result follows its call by
  position (`tool_name`). OpenAI's form pairs them by id, so `messages/1` gives each call an id
  (`call_<message>_<n>`, the same each time the conversation is sent, so the provider's prompt
  cache still matches) and each result the id of the call it answers. Every call gets an answer:
  one left without a result (a turn that stopped) is answered with a note, and a result whose call
  was dropped from the window becomes a note from the user. Providers such as Anthropic refuse a
  conversation that breaks either rule.

  The request (`body/3`):
    * `provider`: `require_parameters` (only endpoints that take tools), `data_collection: "deny"`
      and `zdr` (default on: only endpoints that neither train on nor retain prompts), and
      `cfg[:providers]` pinned as `only`.
    * `max_tokens` (default 8192): a bound on the answer, which also bounds the worst-case cost
      the spend gate plans for (`Xeito.Allowance`).
    * Anthropic models get a top-level `cache_control`: the provider caches the conversation's
      prefix and moves the breakpoint as it grows. A cache read costs a tenth of the input price.
    * `reasoning` (an effort) and `temperature` only when the tier sets them; otherwise the
      model's defaults. Some models take no temperature at all (Claude Sonnet 5.5's endpoints),
      and with `require_parameters` a parameter no endpoint takes leaves no endpoint.

  The result has the shape of `Xeito.Chat.complete/4`'s, plus `usd` (OpenRouter's own
  `usage.cost`), `cached_tokens` and `served_by` (`openrouter:<model>@<provider>`).
  """

  alias Xeito.Backends
  alias Xeito.Chat.OpenRouter.Stream

  @max_tokens 8192
  @no_result "(no result: the call was not run)"

  @doc "Runs one chat turn on the tier configured by `cfg`."
  @spec complete([map()], [map()], keyword(), (String.t() -> any())) :: {:ok, map()} | {:error, term()}
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

    case Req.request(opts) do
      {:ok, %{status: 200} = resp} -> resp.private.stream |> Stream.finish() |> done(cfg, started)
      {:ok, %{status: status} = resp} -> {:error, {:http, status, Map.get(resp.private, :raw, "")}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp into({:data, data}, {req, %{status: 200} = resp}, on_delta) do
    stream = Map.get(resp.private, :stream, Stream.new())
    {:cont, {req, Req.Response.put_private(resp, :stream, Stream.feed(stream, data, on_delta))}}
  end

  # An error's body is kept as it came, for the message.
  defp into({:data, data}, {req, resp}, _on_delta),
    do: {:cont, {req, Req.Response.put_private(resp, :raw, Map.get(resp.private, :raw, "") <> data)}}

  defp done({:ok, message}, cfg, started) do
    model = Keyword.fetch!(cfg, :model)

    {:ok,
     Map.merge(message, %{
       model: model,
       served_by: message.served_by || "openrouter:" <> model,
       latency_ms: System.monotonic_time(:millisecond) - started,
       first_token_ms: nil
     })}
  end

  defp done(error, _cfg, _started), do: error

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
  @spec messages([map()]) :: [map()]
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
