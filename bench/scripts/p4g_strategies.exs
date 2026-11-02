# P4g step 6: does the self-refine strategy (draft → critique → revise, `Xeito.Machines.SelfRefine`)
# beat a single chat call on prose tasks? Run in-process against the local tier:
#
#   source ~/.config/xeito/tiers.env
#   mix run bench/scripts/p4g_strategies.exs bench/strategies/set.jsonl OUT.json
#
# For each task, both variants run as one-shot turns in a scratch workspace (no tools), and the
# local model judges the two answers pairwise, twice with the order swapped, so a position bias
# cancels: a variant wins a task only when it wins both orders. The summary has wins, ties, the
# tokens and wall time of each variant, and every answer, for reading.

alias Xeito.{Chat, Session}

[set, out] = System.argv()
workspace = Path.join(System.tmp_dir!(), "xeito-strategies-#{System.unique_integer([:positive])}")
File.mkdir_p!(workspace)

tasks =
  set
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.map(&JSON.decode!/1)

{:ok, id} = Session.start(cwd: workspace)
Session.subscribe(id)

run = fn opts, text ->
  started = System.monotonic_time(:millisecond)
  :ok = Session.one_shot(id, text, opts)

  wait = fn wait, usage ->
    receive do
      {:xeito, _, %{type: "turn_finished", attrs: attrs}} -> {attrs["answer"] || "", usage}
      {:xeito, _, %{type: "effect_completed", attrs: %{"kind" => :chat, "result" => r}}} -> wait.(wait, usage + (r[:tokens_in] || 0) + (r[:tokens_out] || 0))
      {:xeito, _, _} -> wait.(wait, usage)
    after
      900_000 -> {"(timeout)", usage}
    end
  end

  {answer, tokens} = wait.(wait, 0)
  %{answer: answer, tokens: tokens, ms: System.monotonic_time(:millisecond) - started}
end

judge = fn request, a, b ->
  prompt = """
  Request:
  #{request}

  Answer A:
  #{a}

  Answer B:
  #{b}

  Which answer fulfils the request better: correct, complete, within the limits the request sets, and clear? Reply with exactly one word: A, B or tie.
  """

  case Chat.complete([%{role: "user", content: prompt}], [], tier: :local, think: false) do
    {:ok, %{content: content}} ->
      content |> String.trim() |> String.upcase() |> String.first() |> then(&(if &1 in ["A", "B"], do: &1, else: "tie"))
    {:error, _} -> "tie"
  end
end

results =
  for task <- tasks do
    IO.puts(:stderr, "#{task["id"]}: single call")
    single = run.([tools: false], task["request"])
    IO.puts(:stderr, "#{task["id"]}: self-refine")
    refined = run.([machine: "self_refine", tools: false], task["request"])

    first = judge.(task["request"], single.answer, refined.answer)
    second = judge.(task["request"], refined.answer, single.answer)

    verdict =
      cond do
        first == "B" and second == "A" -> "refine"
        first == "A" and second == "B" -> "single"
        true -> "tie"
      end

    IO.puts(:stderr, "#{task["id"]}: #{verdict} (#{first}/#{second})")
    %{id: task["id"], verdict: verdict, judgments: [first, second], single: single, refine: refined}
  end

summary = %{
  tasks: length(results),
  wins: Enum.frequencies_by(results, & &1.verdict),
  tokens: %{single: Enum.sum(Enum.map(results, & &1.single.tokens)), refine: Enum.sum(Enum.map(results, & &1.refine.tokens))},
  ms: %{single: Enum.sum(Enum.map(results, & &1.single.ms)), refine: Enum.sum(Enum.map(results, & &1.refine.ms))},
  results: results
}

File.write!(out, JSON.encode!(summary))
IO.puts(:stderr, "wins: #{inspect(summary.wins)} · tokens single #{summary.tokens.single} refine #{summary.tokens.refine} · ms single #{summary.ms.single} refine #{summary.ms.refine}")
File.rm_rf!(workspace)
