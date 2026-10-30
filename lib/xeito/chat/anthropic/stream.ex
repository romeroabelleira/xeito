defmodule Xeito.Chat.Anthropic.Stream do
  @moduledoc """
  Reads the Claude API's streamed message (server-sent events) into one assistant message.

    * chunks may split a line; `feed/3` buffers the rest
    * text deltas go to `on_delta` as they arrive; thinking is not passed on
    * tool calls are assembled from `tool_use` blocks and their `input_json_delta` fragments, by index
    * the model and the prompt's token counts come from `message_start`, the answer's tokens and the
      stop reason from `message_delta`; a `fallback` block names the model that took over
    * an `error` event makes `finish/1` return an error
  """

  @type t :: map()

  @doc "An empty stream."
  @spec new() :: t()
  def new, do: %{buffer: "", content: [], blocks: %{}, usage: %{}, model: nil, stop: nil, error: nil}

  @doc "Adds a chunk of the response body."
  @spec feed(t(), binary(), (String.t() -> any())) :: t()
  def feed(acc, data, on_delta) do
    {lines, [rest]} = (acc.buffer <> data) |> String.split("\n") |> Enum.split(-1)
    Enum.reduce(lines, %{acc | buffer: rest}, &line(&1, &2, on_delta))
  end

  @doc "The message read so far, after the last chunk: its text, calls, usage (the API's fields), model and stop reason."
  @spec finish(t()) :: {:ok, map()} | {:error, term()}
  def finish(acc) do
    acc = line(acc.buffer, %{acc | buffer: ""}, fn _ -> :ok end)
    message(acc)
  end

  defp message(%{error: nil} = acc) do
    {:ok,
     %{
       content: acc.content |> Enum.reverse() |> IO.iodata_to_binary(),
       tool_calls: calls(acc.blocks),
       usage: acc.usage,
       model: acc.model,
       finish_reason: acc.stop
     }}
  end

  defp message(acc), do: {:error, {:anthropic, acc.error}}

  defp line("data: " <> json, acc, on_delta), do: event(decode(String.trim(json)), acc, on_delta)
  defp line(_line, acc, _on_delta), do: acc

  defp event(%{"type" => type} = e, acc, on_delta), do: event(type, e, acc, on_delta)
  defp event(_other, acc, _on_delta), do: acc

  defp event("error", e, acc, _on_delta), do: %{acc | error: e["error"]}
  defp event("message_" <> _start_or_delta, e, acc, _on_delta), do: message_event(e, acc)
  defp event("content_block_start", e, acc, _on_delta), do: start(e["content_block"], e["index"], acc)
  defp event("content_block_delta", e, acc, on_delta), do: delta(e["delta"], e["index"], acc, on_delta)
  defp event(_type, _e, acc, _on_delta), do: acc

  # `message_start` names the model and counts the prompt; `message_delta` counts the answer and says why it stopped.
  defp message_event(e, acc) do
    message = Map.get(e, "message", %{})

    %{
      acc
      | model: Map.get(message, "model", acc.model),
        stop: Map.get(e["delta"] || %{}, "stop_reason", acc.stop),
        usage: acc.usage |> Map.merge(Map.get(message, "usage", %{})) |> Map.merge(Map.get(e, "usage", %{}))
    }
  end

  defp start(%{"type" => "tool_use", "name" => name}, i, acc), do: put_in(acc.blocks[i], %{name: name, arguments: ""})
  defp start(%{"type" => "fallback"} = block, _i, acc), do: %{acc | model: get_in(block, ["to", "model"]) || acc.model}
  defp start(_block, _i, acc), do: acc

  defp delta(%{"type" => "text_delta", "text" => text}, _i, acc, on_delta), do: text(acc, text, on_delta)

  defp delta(%{"type" => "input_json_delta", "partial_json" => json}, i, acc, _on_delta),
    do:
      update_in(
        acc.blocks,
        &Map.update(&1, i, %{name: nil, arguments: json}, fn b -> %{b | arguments: b.arguments <> json} end)
      )

  defp delta(_delta, _i, acc, _on_delta), do: acc

  defp text(acc, text, _on_delta) when text in [nil, ""], do: acc

  defp text(acc, text, on_delta) do
    on_delta.(text)
    %{acc | content: [text | acc.content]}
  end

  defp calls(blocks) do
    blocks
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_i, c} -> %{name: c.name, arguments: arguments(c.arguments)} end)
  end

  defp arguments(""), do: %{}

  defp arguments(text) do
    case JSON.decode(text) do
      {:ok, map} when is_map(map) -> map
      _ -> %{"_raw" => text}
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end
end
