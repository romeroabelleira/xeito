defmodule Xeito.Promotion do
  @moduledoc """
  The first half of promotion (`docs/architecture/05-event-log-and-process-mining.md#promotion-from-free-chat-to-skills-and-machines`):
  from the log's free-chat turns to **candidates** for a skill or a machine.

    * `trace/3`: what one turn did: its prompt and intent, its steps (tool calls, abstracted:
      `read`, `edit`, `write`, `check` for the quick check, `bash:<verb>`), its outcome and cost.
    * `clusters/2`: turns whose prompts share most of their words, with the same intent. Words
      for now; embeddings later (P7), which would also bring "write tests" and "add a test" together.
    * `summary/1`: a cluster's size, success, mean cost, and its variants (step sequences with
      repeats collapsed), the dominant one first.
    * `target/2`: the rule-based `PromotionTarget`: `:machine`, `:skill` or `:none`, with the reason.

  `mix xeito.candidates` prints the report.
  """

  alias Xeito.Effect
  alias Xeito.Machines.Chat

  @type outcome :: :answered | :failed | :stopped | :halted | :overruled

  # Tools whose first argument says what they do (`git diff`, `mix test`).
  @two_word ~w(git mix npm pnpm yarn cargo go make bundle python python3 docker kubectl)
  @test_steps ["check", "bash:pytest"] ++
                Enum.map(~w(mix npm pnpm yarn cargo go make), &"bash:#{&1} test")
  @stopwords ~w(a an the for to of in on at and or please me my it its this that these those is are be with from into can could would should you i we)

  @doc """
  The trace of a finished free-chat turn from its log entries (`[{seq, type, term}]`) and its
  intent; `nil` for any other run, or one still running.
  """
  @spec trace(String.t(), [tuple()], atom()) :: map() | nil
  def trace(run, entries, intent) do
    with {:run_started, Chat, _version, input} <- term(entries, "run_started"),
         {:run_finished, status, _leaf, ctx} <- term(entries, "run_finished") do
      effects = for {_, "effect_requested", {:effect_requested, effect}} <- entries, do: effect

      %{
        run: run,
        prompt: input[:request] || input[:prompt] || "",
        intent: intent,
        steps: effects |> Enum.map(&step/1) |> Enum.reject(&is_nil/1),
        outcome: outcome(status, ctx, entries),
        turns: Enum.count(effects, &(&1.kind == :chat)),
        tokens: Map.get(ctx, :tokens_in, 0) + Map.get(ctx, :tokens_out, 0)
      }
    else
      _ -> nil
    end
  end

  defp term(entries, type), do: Enum.find_value(entries, fn {_, t, term} -> if t == type, do: term end)

  defp step(%Effect{kind: :bash, reply: :verified}), do: "check"
  defp step(%Effect{kind: :bash, args: %{cmd: cmd}}), do: "bash:" <> verb(cmd)
  defp step(%Effect{kind: kind}) when kind in [:read, :write, :edit], do: Atom.to_string(kind)
  defp step(_effect), do: nil

  defp verb(cmd) do
    case String.split(cmd) do
      [tool, sub | _] when tool in @two_word -> if String.starts_with?(sub, "-"), do: tool, else: tool <> " " <> sub
      [tool | _] -> tool
      [] -> ""
    end
  end

  defp outcome(:halted, _ctx, _entries), do: :halted
  defp outcome(:failed, _ctx, _entries), do: :failed

  defp outcome(_status, ctx, entries) do
    cond do
      Map.get(ctx, :stopped, false) -> :stopped
      Enum.any?(entries, &overruled?/1) -> :overruled
      true -> :answered
    end
  end

  defp overruled?({_, "event_received", {:event, name, _data, :human}}), do: name in [:denied, :instructed]
  defp overruled?(_entry), do: false

  @doc "The steps with consecutive repeats collapsed: a variant."
  @spec variant([String.t()]) :: [String.t()]
  def variant(steps), do: Enum.dedup(steps)

  @doc "A prompt's words: lowercase, singular, without filler or code names (paths, modules, identifiers)."
  @spec words(String.t()) :: MapSet.t()
  def words(prompt) do
    prompt
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&Regex.match?(~r/[.\/_\d]|\p{Ll}\p{Lu}/u, &1))
    |> Enum.map(&(&1 |> String.downcase() |> String.replace(~r/[^\p{L}]/u, "")))
    |> Enum.reject(&(&1 == "" or &1 in @stopwords))
    |> MapSet.new(&singular/1)
  end

  defp singular(word) do
    if String.length(word) > 3 and String.ends_with?(word, "s") and not String.ends_with?(word, "ss"),
      do: String.slice(word, 0..-2//1),
      else: word
  end

  @doc "The share of words two prompts have in common (Jaccard), 0.0 to 1.0."
  @spec similarity(String.t(), String.t()) :: float()
  def similarity(a, b) do
    {a, b} = {words(a), words(b)}

    case MapSet.size(MapSet.union(a, b)) do
      0 -> 0.0
      union -> MapSet.size(MapSet.intersection(a, b)) / union
    end
  end

  @doc """
  Groups traces whose prompts are at least `threshold` similar to one already in a group with
  the same intent. Groups and their members keep the traces' order.
  """
  @spec clusters([map()], float()) :: [[map()]]
  def clusters(traces, threshold) do
    Enum.reduce(traces, [], fn trace, clusters ->
      case Enum.find_index(clusters, &joins?(&1, trace, threshold)) do
        nil -> clusters ++ [[trace]]
        i -> List.update_at(clusters, i, &(&1 ++ [trace]))
      end
    end)
  end

  defp joins?([%{intent: intent} | _] = cluster, %{intent: intent} = trace, threshold),
    do: Enum.any?(cluster, &(similarity(&1.prompt, trace.prompt) >= threshold))

  defp joins?(_cluster, _trace, _threshold), do: false

  @doc "A cluster's size, share answered, mean turns and tokens, variants (most frequent first) and examples."
  @spec summary([map()]) :: map()
  def summary([first | _] = cluster) do
    runs = length(cluster)
    variants = cluster |> Enum.map(&variant(&1.steps)) |> frequencies()

    %{
      intent: first.intent,
      runs: runs,
      success: Enum.count(cluster, &(&1.outcome == :answered)) / runs,
      turns: Float.round(Enum.sum_by(cluster, & &1.turns) / runs, 1),
      tokens: round(Enum.sum_by(cluster, & &1.tokens) / runs),
      variants: variants,
      dominant: (variants |> hd() |> elem(1)) / runs,
      examples: cluster |> Enum.map(& &1.prompt) |> Enum.uniq() |> Enum.take(3)
    }
  end

  # Counts in order of first appearance, then most frequent first (a stable sort keeps ties in that order).
  defp frequencies(items) do
    items
    |> Enum.reduce([], fn item, acc ->
      case List.keyfind(acc, item, 0) do
        nil -> acc ++ [{item, 1}]
        {_, n} -> List.keyreplace(acc, item, 0, {item, n + 1})
      end
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  @doc """
  The rule-based promotion target of a cluster, with the reason. Options: `:min_runs`
  (default 5). A machine needs one variant in at least 70% of the runs and a checkable end; a
  frequent, successful cluster without one is a skill.
  """
  @spec target(map(), keyword()) :: {:machine | :skill | :none, String.t()}
  def target(summary, opts) do
    min_runs = Keyword.get(opts, :min_runs, 5)
    [{top, _} | _] = summary.variants

    cond do
      summary.runs < min_runs ->
        {:none, "#{runs(summary.runs)}; candidates need #{min_runs}"}

      summary.success < 0.5 ->
        {:none, "answered in #{pct(summary.success)}% of runs: a bug report, not a candidate"}

      summary.turns < 3 ->
        {:none, "#{summary.turns} model turns on average: cheap already"}

      summary.dominant >= 0.7 and List.last(top) in @test_steps ->
        {:machine, "#{pct(summary.dominant)}% of runs follow one variant, which ends in a check"}

      summary.dominant >= 0.7 ->
        {:skill, "one variant dominates, but it ends without a check"}

      true ->
        {:skill, "no variant dominates (#{pct(summary.dominant)}% at most): guidance, not fixed steps"}
    end
  end

  defp pct(share), do: round(share * 100)

  @doc false
  def runs(1), do: "1 run"
  def runs(n), do: "#{n} runs"
end
