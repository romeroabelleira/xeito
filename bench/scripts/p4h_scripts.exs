# P4h step 6: does the `script` tool pay on busywork? Each task is one chat turn in a prepared
# workspace, run twice on the local tier: with the plain tools (`read`, `bash`, `write`, `edit`)
# and with `script` offered as well. Run in-process:
#
#   source ~/.config/xeito/tiers.env
#   mix run bench/scripts/p4h_scripts.exs TASKS.json OUT.json [REPEATS]
#
# TASKS.json is a list of `{"id", "workspace", "request", "check"}`; `check` names the success
# check below with its data (`{"kind": "mentions", "all": [...]}`: every string appears in the
# answer; `{"kind": "rated", "ids": [...], "range": [lo, hi]}`: every id appears with a number in
# the range after it). A command Risk sends to review is approved at once and counted as decided
# by a human. Measured per run: success, model turns, tokens, wall time, the tool calls, how many
# of them the rules decided, how many a human and how many failed, and the script calls made. The
# summary has the means per variant and every answer, for reading.

alias Xeito.Session

[tasks_file, out | rest] = System.argv()

repeats =
  case rest,
    do: (
      [n] -> String.to_integer(n)
      [] -> 1
    )

tasks = tasks_file |> File.read!() |> JSON.decode!()

plain = ~w(read bash write edit)
# `scripts` offers the script tool beside the plain ones; `script_only` leaves the model nothing else.
variants = [plain: plain, scripts: plain ++ ["script"], script_only: ["script"]]

defmodule Bench.P4h do
  @moduledoc false
  def run(id, tools, text) do
    started = System.monotonic_time(:millisecond)
    :ok = Session.one_shot(id, text, tools: tools, think: false)
    acc = wait(id, %{answer: nil, turns: 0, tokens: 0, rules: 0, human: 0, scripts: 0, calls: 0, failed: 0, status: nil})
    Map.put(acc, :ms, System.monotonic_time(:millisecond) - started)
  end

  defp wait(id, acc) do
    receive do
      {:xeito, _, %{type: "turn_finished", attrs: attrs}} ->
        %{acc | answer: attrs["answer"] || "", status: attrs["status"]}

      {:xeito, _, %{type: "human_needed"}} ->
        :ok = Session.approve(id, nil)
        wait(id, %{acc | human: acc.human + 1})

      {:xeito, _, %{type: "effect_completed", attrs: %{"kind" => :chat, "result" => r}}} ->
        wait(id, %{acc | turns: acc.turns + 1, tokens: acc.tokens + (r[:tokens_in] || 0) + (r[:tokens_out] || 0)})

      {:xeito, _, %{type: "effect_requested", attrs: %{"kind" => :script}}} ->
        wait(id, %{acc | scripts: acc.scripts + 1})

      {:xeito, _, %{type: "effect_requested", attrs: %{"kind" => kind}}} when kind in [:bash, :read, :write, :edit] ->
        wait(id, %{acc | calls: acc.calls + 1})

      {:xeito, _, %{type: "effect_completed", attrs: %{"kind" => kind, "result" => r}}}
      when kind in [:bash, :read, :write, :edit, :script] ->
        failed = if r[:ok] == false or (r[:exit_status] || 0) != 0, do: 1, else: 0
        wait(id, %{acc | failed: acc.failed + failed})

      {:xeito, _, %{type: "decision_made", attrs: %{"decision_type" => "Xeito.Decisions.Risk", "actor" => :rule}}} ->
        wait(id, %{acc | rules: acc.rules + 1})

      {:xeito, _, _} ->
        wait(id, acc)
    after
      1_200_000 -> %{acc | answer: acc.answer || "(timeout)", status: :timeout}
    end
  end

  def success?(%{"kind" => "mentions", "all" => all}, answer), do: Enum.all?(all, &String.contains?(answer, &1))

  def success?(%{"kind" => "rated", "ids" => ids, "range" => [lo, hi]}, answer) do
    # The number in the cell after the id's (a table row), else the first number after the id.
    Enum.all?(ids, fn id ->
      case Regex.run(~r/#{id}\s*\|\s*(\d+)/, answer) || Regex.run(~r/#{id}\D{0,80}?(\d+)/s, answer) do
        [_, n] -> String.to_integer(n) in lo..hi
        nil -> false
      end
    end)
  end

  def coverage(%{"all" => all}, answer), do: Enum.count(all, &String.contains?(answer, &1)) / max(length(all), 1)
  def coverage(%{"ids" => ids}, answer), do: Enum.count(ids, &String.contains?(answer, &1)) / max(length(ids), 1)
end

results =
  for task <- tasks, {variant, tools} <- variants, rep <- 1..repeats do
    IO.puts(:stderr, "#{task["id"]} · #{variant} · #{rep}")
    {:ok, id} = Session.start(cwd: task["workspace"])
    Session.subscribe(id)
    r = Bench.P4h.run(id, tools, task["request"])
    Session.close(id)
    success = Bench.P4h.success?(task["check"], r.answer)
    coverage = Bench.P4h.coverage(task["check"], r.answer)

    IO.puts(
      :stderr,
      "  #{if success, do: "ok", else: "FAIL"} coverage #{Float.round(coverage, 2)} · turns #{r.turns} · tokens #{r.tokens} · #{div(r.ms, 1000)} s · calls #{r.calls} (rules #{r.rules}, human #{r.human}, failed #{r.failed}) · scripts #{r.scripts} · #{r.status}"
    )

    Map.merge(r, %{task: task["id"], variant: variant, rep: rep, success: success, coverage: coverage})
  end

mean = fn rows, key -> if rows == [], do: 0, else: Enum.sum(Enum.map(rows, &Map.fetch!(&1, key))) / length(rows) end

summary =
  for {variant, _} <- variants, into: %{} do
    rows = Enum.filter(results, &(&1.variant == variant))

    {variant,
     %{
       runs: length(rows),
       successes: Enum.count(rows, & &1.success),
       coverage: mean.(rows, :coverage),
       turns: mean.(rows, :turns),
       tokens: mean.(rows, :tokens),
       ms: mean.(rows, :ms),
       calls: mean.(rows, :calls),
       rules: mean.(rows, :rules),
       human: mean.(rows, :human),
       failed: mean.(rows, :failed),
       scripts: mean.(rows, :scripts)
     }}
  end

File.write!(out, JSON.encode!(%{summary: summary, results: results}))
IO.puts(:stderr, inspect(summary, pretty: true))
