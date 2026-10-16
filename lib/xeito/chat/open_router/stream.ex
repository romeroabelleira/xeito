defmodule Xeito.Chat.OpenRouter.Stream do
  @moduledoc """
  Reads OpenRouter's streamed chat completion (server-sent events) into one assistant message.

    * chunks may split a line; `feed/3` buffers the rest
    * text deltas go to `on_delta` as they arrive
    * tool calls are assembled from fragments by `index`
    * usage, cost, model and provider come from the last chunk
    * comment lines and `[DONE]` are skipped; an `error` chunk makes `finish/1` return an error
  """

  @type t :: map()

  @doc "An empty stream."
  @spec new() :: t()
  def new, do: %{buffer: "", content: [], calls: %{}, usage: %{}, model: nil, provider: nil, error: nil}

  @doc "Adds a chunk of the response body."
  @spec feed(t(), binary(), (String.t() -> any())) :: t()
  def feed(acc, data, on_delta) do
    {lines, [rest]} = (acc.buffer <> data) |> String.split("\n") |> Enum.split(-1)
    Enum.reduce(lines, %{acc | buffer: rest}, &line(&1, &2, on_delta))
  end

  @doc "The message read so far, after the last chunk."
  @spec finish(t()) :: {:ok, map()} | {:error, term()}
  def finish(acc) do
    acc = line(acc.buffer, %{acc | buffer: ""}, fn _ -> :ok end)
    message(acc)
  end

  defp message(%{error: nil} = acc) do
    usage = acc.usage

    {:ok,
     %{
       content: acc.content |> Enum.reverse() |> IO.iodata_to_binary(),
       tool_calls: calls(acc.calls),
       tokens_in: usage["prompt_tokens"] || 0,
       tokens_out: usage["completion_tokens"] || 0,
       cached_tokens: get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0,
       usd: (usage["cost"] || 0) * 1.0,
       served_by: served_by(acc.model, acc.provider)
     }}
  end

  defp message(acc), do: {:error, {:openrouter, acc.error}}

  defp line("data: " <> json, acc, on_delta), do: chunk(decode(String.trim(json)), acc, on_delta)
  defp line(_line, acc, _on_delta), do: acc

  defp chunk(%{"error" => error}, acc, _on_delta), do: %{acc | error: error}

  defp chunk(%{} = chunk, acc, on_delta) do
    delta = get_in(chunk, ["choices", Access.at(0), "delta"]) || %{}

    acc
    |> text(delta["content"], on_delta)
    |> Map.update!(:calls, &Enum.reduce(delta["tool_calls"] || [], &1, fn call, calls -> fragment(call, calls) end))
    |> Map.merge(
      for {k, v} <- [usage: chunk["usage"], model: chunk["model"], provider: chunk["provider"]], v, into: %{}, do: {k, v}
    )
  end

  defp chunk(nil, acc, _on_delta), do: acc

  defp text(acc, text, _on_delta) when text in [nil, ""], do: acc

  defp text(acc, text, on_delta) do
    on_delta.(text)
    %{acc | content: [text | acc.content]}
  end

  # The first fragment of a call names it; later ones add to its arguments.
  defp fragment(%{"index" => i} = call, calls) do
    %{"name" => name, "arguments" => args} = Map.merge(%{"name" => nil, "arguments" => ""}, call["function"] || %{})
    args = args || ""
    Map.update(calls, i, %{name: name, arguments: args}, &%{&1 | name: &1.name || name, arguments: &1.arguments <> args})
  end

  defp calls(calls) do
    calls
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

  defp served_by(nil, _provider), do: nil
  defp served_by(model, nil), do: "openrouter:" <> model
  defp served_by(model, provider), do: "openrouter:#{model}@#{provider}"

  defp decode("[DONE]"), do: nil

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end
end
