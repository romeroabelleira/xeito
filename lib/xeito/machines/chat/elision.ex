defmodule Xeito.Machines.Chat.Elision do
  @moduledoc """
  Which old tool outputs a chat turn's model request replaces with stubs, before it is fitted.

  `elide/1` stubs (`Xeito.Chat.Window.stub/1`) old tool output in whole batches of 6, so the
  prompt prefix (and the server's prompt cache) changes rarely. Kept whole: the
  last 4 outputs, outputs `Xeito.Chat.Window.elidable?/1` refuses (small ones, skill
  instructions, results without a ref), and the latest whole read (`read:` on the message) of
  each of the last 3 project files read. It only stubs messages, never drops or reorders them,
  and it is pure, so a replay of the turn sends the same request.
  """

  alias Xeito.Chat.Window

  @keep_whole 4
  @elide_batch 6
  @keep_reads 3

  @doc "The messages with the old tool outputs that are due replaced by stubs."
  @spec elide([map()]) :: [map()]
  def elide(messages) do
    kept = latest_reads(messages)

    candidates =
      for {%{role: "tool"} = m, i} <- Enum.with_index(messages),
          Window.elidable?(m) and i not in kept,
          do: i

    cut = div(max(length(candidates) - @keep_whole, 0), @elide_batch) * @elide_batch
    elided = candidates |> Enum.take(cut) |> MapSet.new()

    messages
    |> Enum.with_index()
    |> Enum.map(fn {m, i} -> if i in elided, do: Window.stub(m), else: m end)
  end

  defp latest_reads(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {%{read: path}, i}, latest -> Map.put(latest, path, i)
      _, latest -> latest
    end)
    |> Map.values()
    |> Enum.sort(:desc)
    |> Enum.take(@keep_reads)
    |> MapSet.new()
  end
end
