defmodule Xeito.Chat.Window do
  @moduledoc """
  The context window of a chat request: what a conversation costs in tokens, and how it is made
  to fit before it is sent. Pure functions, so a replay reproduces the request exactly.

  Ollama does not refuse a prompt that is too long: it cuts it from the *front*, which drops the
  system prompt (and `AGENTS.md` in it) first, and says nothing. So the chat machine fits every
  request into its budget itself (`fit/2`), in this order, stopping as soon as it fits:

    1. old tool outputs become stubs, except the last 4 (as `Xeito.Machines.Chat.elide/1`
       does in batches, here all at once);
    2. the oldest earlier turns are dropped, whole, with a note saying how many messages were
       left out. A turn starts at a user message, so a tool result never loses its call;
    3. the largest message of the current turn is shortened in the middle.

  The system prompt is set aside before any of this and is never changed: a system prompt that
  does not fit on its own is an error, not a cut. The current prompt is part of the current
  turn, which only step 3 touches.

  Tokens are estimated from characters (`estimate/2`), at a conservative 3.0 characters per
  token until the server has reported a real count (`calibrate/2`).
  """

  @type message :: map()
  @type report :: %{dropped: non_neg_integer(), stubbed: non_neg_integer(), shortened: non_neg_integer()}

  @default_chars_per_token 3.0
  # Template tokens per message (role markers, separators).
  @per_message 4
  @keep_whole 4
  @elide_min 400
  # A message is shortened only while it is longer than this.
  @shorten_min 2_000

  @doc "The conservative characters-per-token ratio used before any measurement."
  @spec default_chars_per_token() :: float()
  def default_chars_per_token, do: @default_chars_per_token

  @doc "Estimated tokens of `messages` at `chars_per_token`."
  @spec estimate([message()], number()) :: non_neg_integer()
  def estimate(messages, chars_per_token) do
    messages
    |> Enum.map(&(ceil(chars(&1) / chars_per_token) + @per_message))
    |> Enum.sum()
  end

  @doc "Characters of `messages`: their text and their tool calls."
  @spec characters([message()]) :: non_neg_integer()
  def characters(messages), do: messages |> Enum.map(&chars/1) |> Enum.sum()

  defp chars(message), do: text_length(message[:content]) + calls_length(message[:tool_calls])

  defp text_length(text) when is_binary(text), do: String.length(text)
  defp text_length(_), do: 0

  defp calls_length(calls) when is_list(calls), do: calls |> JSON.encode!() |> String.length()
  defp calls_length(_), do: 0

  @doc """
  Fits `messages` (system prompt first) into `opts[:budget]` tokens.

  `opts[:keep_from]` is the index of the current prompt: the messages between the system prompt
  and it are the earlier conversation, which may be dropped. `opts[:chars_per_token]` defaults to
  `default_chars_per_token/0`.
  """
  @spec fit([message()], keyword()) ::
          {:ok, [message()], report()}
          | {:error, {:system_too_large | :over_budget, non_neg_integer(), non_neg_integer()}}
  def fit([system | rest], opts) do
    budget = Keyword.fetch!(opts, :budget)
    cpt = Keyword.get(opts, :chars_per_token, @default_chars_per_token)
    own = estimate([system], cpt)
    room = %{tokens: budget - own, cpt: cpt}

    if room.tokens <= 0 do
      {:error, {:system_too_large, own, budget}}
    else
      {earlier, current} = Enum.split(rest, Keyword.fetch!(opts, :keep_from) - 1)
      parts = %{earlier: earlier, current: current, report: %{dropped: 0, stubbed: 0, shortened: 0}}
      steps(parts, room, system, budget)
    end
  end

  defp steps(parts, room, system, budget) do
    parts
    |> until_fits(room, &stub_old/1)
    |> until_fits(room, &drop_oldest(&1, room))
    |> until_fits(room, &shorten_largest(&1, room))
    |> result(room, system, budget)
  end

  defp until_fits(parts, room, step), do: if(fits?(parts, room), do: parts, else: step.(parts))

  defp fits?(parts, room), do: estimate(assemble(parts), room.cpt) <= room.tokens

  defp result(parts, room, system, budget) do
    messages = [system | assemble(parts)]

    if fits?(parts, room),
      do: {:ok, messages, parts.report},
      else: {:error, {:over_budget, estimate(messages, room.cpt), budget}}
  end

  defp assemble(%{earlier: earlier, current: current, report: %{dropped: 0}}), do: earlier ++ current
  defp assemble(%{earlier: earlier, current: current, report: %{dropped: n}}), do: [note(n) | earlier ++ current]

  defp note(n), do: %{role: "user", content: "[#{n} earlier messages omitted to fit the context window.]"}

  # --- step 1: stubs ---------------------------------------------------------------------------

  defp stub_old(%{earlier: earlier, current: current} = parts) do
    all = earlier ++ current
    candidates = for {m, i} <- Enum.with_index(all), elidable?(m), do: i
    stubbed = candidates |> Enum.drop(-@keep_whole) |> MapSet.new()
    all = Enum.map(Enum.with_index(all), fn {m, i} -> if i in stubbed, do: stub(m), else: m end)
    {earlier, current} = Enum.split(all, length(earlier))
    %{parts | earlier: earlier, current: current, report: %{parts.report | stubbed: MapSet.size(stubbed)}}
  end

  @doc "Whether a tool result may become a stub: long enough, readable back by its ref, not a skill."
  @spec elidable?(message()) :: boolean()
  def elidable?(%{tool_name: "skill"}), do: false

  def elidable?(%{role: "tool", content: content} = m),
    do: is_binary(content) and String.length(content) > @elide_min and Map.has_key?(m, :ref)

  def elidable?(_message), do: false

  @doc "A tool result replaced by a one-line stub that says what it was and how to read it back."
  @spec stub(message()) :: message()
  def stub(%{content: content, ref: ref} = m) do
    lines = length(String.split(content, "\n"))
    about = Map.get(m, :about, m[:tool_name] || "tool call")

    %{
      m
      | content:
          "[elided to save context: #{about} (#{lines} lines). " <>
            "If you still need it, read with result: \"#{ref}\".]"
    }
  end

  # --- step 2: dropping earlier turns ------------------------------------------------------------

  defp drop_oldest(%{earlier: []} = parts, _room), do: parts

  defp drop_oldest(parts, room) do
    {span, rest} = first_span(parts.earlier)
    parts = %{parts | earlier: rest, report: Map.update!(parts.report, :dropped, &(&1 + length(span)))}
    if fits?(parts, room), do: parts, else: drop_oldest(parts, room)
  end

  # The leading messages up to (not including) the next user message: one turn, or the tail of
  # one when the history starts mid-turn.
  defp first_span([first | rest]) do
    {tail, after_span} = Enum.split_while(rest, &(&1.role != "user"))
    {[first | tail], after_span}
  end

  # --- step 3: shortening --------------------------------------------------------------------

  defp shorten_largest(parts, room) do
    case largest(parts.current) do
      nil ->
        parts

      i ->
        current = List.update_at(parts.current, i, &cut_middle/1)
        parts = %{parts | current: current, report: Map.update!(parts.report, :shortened, &(&1 + 1))}
        if fits?(parts, room), do: parts, else: shorten_largest(parts, room)
    end
  end

  defp largest(messages) do
    messages
    |> Enum.with_index()
    |> Enum.filter(fn {m, _} -> text_length(m[:content]) > @shorten_min end)
    |> Enum.max_by(fn {m, _} -> text_length(m.content) end, fn -> {nil, nil} end)
    |> elem(1)
  end

  # Keeps the first and the last quarter, so both ends of a long output stay readable.
  defp cut_middle(%{content: content} = m) do
    length = String.length(content)
    keep = div(length, 4)
    cut = length - 2 * keep
    middle = "\n[… #{cut} characters cut to fit the context window …]\n"
    %{m | content: String.slice(content, 0, keep) <> middle <> String.slice(content, length - keep, keep)}
  end

  # --- measurements ------------------------------------------------------------------------------

  @doc """
  The characters per token measured on a request (`chars` sent, `tokens` the server counted),
  within 2.0 and 4.5; the default when the server reported nothing.
  """
  @spec calibrate(non_neg_integer(), non_neg_integer()) :: float()
  def calibrate(_chars, 0), do: @default_chars_per_token
  def calibrate(chars, tokens), do: (chars / tokens) |> max(2.0) |> min(4.5)

  @doc """
  Whether the server cut a prompt: Ollama keeps n_ctx/2 + 1 to 3 tokens of a prompt longer than
  its context (measured 2026-10 on 0.32 and 0.35), and reports that as the prompt's size.
  """
  @spec truncated?(non_neg_integer(), pos_integer() | nil) :: boolean()
  def truncated?(_tokens, nil), do: false
  def truncated?(tokens, context), do: tokens in (div(context, 2) + 1)..(div(context, 2) + 3)
end
