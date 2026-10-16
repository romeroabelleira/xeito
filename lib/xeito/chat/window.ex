defmodule Xeito.Chat.Window do
  @moduledoc """
  Token estimates for a chat request and the pure functions that fit it into the context window.

  Servers such as Ollama silently cut an overlong prompt from the front, so `fit/2` makes every
  request fit, stopping as soon as it does:

    1. old tool outputs become stubs, except the last 4;
    2. the oldest earlier turns are dropped whole (a turn starts at a user message, so a tool
       result never loses its call), with a note of how many messages were left out;
    3. the largest message of the current turn is shortened in the middle.

  Invariants: the system prompt is never changed (too large on its own is an error); a summary
  of earlier turns is never dropped and stays right after the system prompt; only step 3
  touches the current turn.

  Summaries: `summary_split/2` says when the earlier conversation (over 60% of the budget or 40
  messages) should have its oldest turns summarised, down to 30% and 20 messages;
  `summary_request/2` and `summary_message/2` build the call and its result.

  Tokens are estimated from characters (`estimate/2`), at 3.0 characters per token until
  `calibrate/2` has a measured ratio.
  """

  @type message :: Xeito.Chat.Message.t()
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
      {pinned, earlier} = Enum.split_while(earlier, &summary?/1)
      parts = %{pinned: pinned, earlier: earlier, current: current, report: %{dropped: 0, stubbed: 0, shortened: 0}}
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

  defp assemble(%{pinned: pinned, earlier: earlier, current: current, report: %{dropped: 0}}),
    do: pinned ++ earlier ++ current

  defp assemble(%{pinned: pinned, earlier: earlier, current: current, report: %{dropped: n}}),
    do: pinned ++ [note(n) | earlier ++ current]

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

  # Up to the next user message: one turn, or the tail of one when the history starts mid-turn.
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

  # Keeps the first and last quarter, or with `max` as much of both ends as fits.
  defp cut_middle(%{content: content} = m, max \\ nil) do
    length = String.length(content)
    keep = if max, do: div(max - 60, 2), else: div(length, 4)
    cut = length - 2 * keep
    middle = "\n[… #{cut} characters cut to fit the context window …]\n"
    %{m | content: String.slice(content, 0, keep) <> middle <> String.slice(content, length - keep, keep)}
  end

  # --- summaries ---------------------------------------------------------------------------------

  @summarise_at 0.6
  @summarise_messages 40
  @keep_at 0.3
  @keep_messages 20
  @summary_max 4_000
  @result_max 1_000
  @args_max 300

  @summary_system """
  You summarise the earlier part of a conversation between a user and a coding assistant, so the \
  assistant can go on without it. Write at most 300 words, under these headings: Goal; Decisions \
  and facts established; Files touched (paths, and what changed); Open questions and next steps. \
  If there is a summary so far, fold it in. Keep paths, names, commands and numbers exact. Leave \
  out what is settled and no longer matters. Write only the summary.
  """

  @doc "Whether a message is a summary of earlier turns (`summary_message/2`)."
  @spec summary?(message()) :: boolean()
  def summary?(message), do: Map.get(message, :summary, false) == true

  @doc """
  `:keep`, or `{span, kept}` when the earlier conversation (without the system prompt) is due for
  a summary: `span` is the oldest whole turns (with any summary so far), `kept` starts at a user
  message. Options: `:budget` (tokens) and `:chars_per_token`.
  """
  @spec summary_split([message()], keyword()) :: :keep | {[message()], [message()]}
  def summary_split(earlier, opts) do
    limits = %{budget: Keyword.fetch!(opts, :budget), cpt: Keyword.get(opts, :chars_per_token, @default_chars_per_token)}
    if over?(earlier, limits, @summarise_at, @summarise_messages), do: span(earlier, [], limits), else: :keep
  end

  defp over?(messages, limits, share, count),
    do: length(messages) > count or estimate(messages, limits.cpt) > share * limits.budget

  defp span(kept, span, limits) do
    if over?(kept, limits, @keep_at, @keep_messages) do
      {turn, rest} = first_span(kept)
      span(rest, span ++ turn, limits)
    else
      {span, kept}
    end
  end

  @doc "The request that has `span` summarised: instructions, then `span` as a transcript, fitted to `opts[:budget]`."
  @spec summary_request([message()], keyword()) :: [message()]
  def summary_request(span, opts) do
    cpt = Keyword.get(opts, :chars_per_token, @default_chars_per_token)
    system = %{role: "system", content: @summary_system}
    room = (Keyword.fetch!(opts, :budget) - estimate([system, %{role: "user", content: ""}], cpt)) * cpt
    [system, %{role: "user", content: span |> transcript() |> cut_to(floor(room))}]
  end

  defp transcript(span), do: Enum.map_join(span, "\n\n", &line/1)

  defp line(%{summary: true, content: content}), do: "Summary so far:\n" <> body(content)
  defp line(%{role: "user", content: content}), do: "User: " <> content
  defp line(%{role: "tool"} = m), do: "Result of #{Map.get(m, :tool_name, "a tool")}: " <> clip(m.content, @result_max)
  defp line(%{role: "assistant"} = m), do: Enum.join(said(m.content) ++ calls(Map.get(m, :tool_calls, [])), "\n")

  defp said(text) when text in [nil, ""], do: []
  defp said(text), do: ["Assistant: " <> text]

  defp calls(calls),
    do: for(%{function: f} <- calls, do: "Assistant called #{f.name} " <> clip(JSON.encode!(f.arguments), @args_max))

  defp clip(text, max) do
    case String.length(text) - max do
      more when more > 0 -> String.slice(text, 0, max) <> " [… #{more} more characters]"
      _ -> text
    end
  end

  defp cut_to(text, max) do
    if String.length(text) <= max, do: text, else: cut_middle(%{content: text}, max).content
  end

  @doc "The summary of `span`, written by the model, as the message that stands for it."
  @spec summary_message(String.t(), [message()]) :: message()
  def summary_message(text, span) do
    covers = span |> Enum.map(&Map.get(&1, :covers, 1)) |> Enum.sum()
    header = "[Summary of the #{covers} earlier messages, which no longer fit the context window:]\n"
    %{role: "user", content: header <> String.slice(String.trim(text), 0, @summary_max), summary: true, covers: covers}
  end

  defp body(content), do: content |> String.split("\n", parts: 2) |> List.last()

  # --- measurements ------------------------------------------------------------------------------

  @doc "Characters per token measured on a request, clamped to 2.0..4.5; the default when `tokens` is 0."
  @spec calibrate(non_neg_integer(), non_neg_integer()) :: float()
  def calibrate(_chars, 0), do: @default_chars_per_token
  def calibrate(chars, tokens), do: (chars / tokens) |> max(2.0) |> min(4.5)

  @doc """
  Whether the server cut a prompt: Ollama reports n_ctx/2 + 1 to 3 prompt tokens for a prompt
  longer than its context.
  """
  @spec truncated?(non_neg_integer(), pos_integer() | nil) :: boolean()
  def truncated?(_tokens, nil), do: false
  def truncated?(tokens, context), do: tokens in (div(context, 2) + 1)..(div(context, 2) + 3)
end
