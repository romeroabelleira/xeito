defmodule Mix.Tasks.Xeito.Candidates do
  @shortdoc "Reports frequent free-chat requests: candidates for a skill or a machine"
  @moduledoc """
  The first half of promotion (`Xeito.Promotion`): reads a workspace's log, groups its free-chat
  turns by similar prompts, and reports the groups that could become a skill or a machine, with
  the evidence: how often, how successful, how costly, and how uniform their steps are.

      mix xeito.candidates [--cwd DIR] [--min-runs N] [--all]

  A free-chat turn is a turn the router sent to the chat machine, after an Intent decision;
  continuations ("go ahead") and small talk are left out. `--min-runs` sets how many runs make a
  candidate (default 5); `--all` also lists the groups that are not candidates, with the reason.

  Nothing is drafted or changed: the report is for a human to read (see
  `docs/architecture/05-event-log-and-process-mining.md#promotion-from-free-chat-to-skills-and-machines`).
  """

  use Mix.Task

  alias Exqlite.Sqlite3
  alias Xeito.Log.Sql
  alias Xeito.Log.Store
  alias Xeito.Promotion

  @switches [cwd: :string, min_runs: :integer, all: :boolean]
  @similar 0.5

  @impl true
  def run(args) do
    if Mix.Tasks.Xeito.help?(args), do: Mix.Tasks.Xeito.help(__MODULE__), else: run_task(args)
  end

  defp run_task(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("compile")
    path = Path.join([Path.expand(opts[:cwd] || "."), ".xeito", "log.sqlite"])
    if !File.exists?(path), do: Mix.raise("no log at #{path}")

    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.set_busy_timeout(db, 10_000)
    :ok = Store.prepare(db)

    try do
      db |> traces() |> report(Keyword.take(opts, [:min_runs]), opts[:all] || false)
    after
      Sqlite3.close(db)
    end
  end

  # The traces of top-level turns (`<session>/tN`) the chat machine ran after an Intent decision.
  defp traces(db) do
    for [run] <- Sql.select(db, "SELECT DISTINCT run_id FROM xeito_term ORDER BY run_id"),
        Regex.match?(~r{^[^/]+/t\d+$}, run),
        intent = intent(db, run),
        intent not in [nil, :other],
        trace = Promotion.trace(run, read_run(db, run), intent),
        do: trace
  end

  # The Intent decision is the result of the turn's escalation run (`<turn>/intent`).
  defp intent(db, run) do
    Enum.find_value(read_run(db, run <> "/intent"), fn
      {_, "run_finished", {:run_finished, _status, _leaf, %{decision: %{value: value}}}} -> value
      _ -> nil
    end)
  end

  defp read_run(db, run),
    do: Store.decode(db, Sql.select(db, "SELECT seq, type, term FROM xeito_term WHERE run_id = ?1 ORDER BY seq", [run]))

  defp report([], _opts, _all), do: Mix.shell().info("no free-chat turns in this log yet")

  defp report(traces, opts, all) do
    rated =
      for cluster <- Promotion.clusters(traces, @similar) do
        summary = Promotion.summary(cluster)
        {target, reason} = Promotion.target(summary, opts)
        {target, reason, summary}
      end

    candidates = Enum.count(rated, fn {target, _, _} -> target != :none end)
    min_runs = Keyword.get(opts, :min_runs, 5)

    Mix.shell().info(
      "#{length(traces)} free-chat turns in #{length(rated)} groups of similar prompts; " <>
        "#{candidates} #{plural(candidates, "candidate")} (at least #{Promotion.runs(min_runs)})\n"
    )

    rated
    |> Enum.filter(fn {target, _, _} -> all or target != :none end)
    |> Enum.sort_by(fn {target, _, s} -> {target == :none, -s.runs * s.turns} end)
    |> Enum.each(&Mix.shell().info(format(&1)))
  end

  defp format({target, reason, s}) do
    [{variant, count} | _] = s.variants

    """
    #{target} · #{Promotion.runs(s.runs)} · intent #{s.intent} · #{round(s.success * 100)}% answered · #{s.turns} model turns · #{s.tokens} tokens
      because #{reason}
      variant (#{count} of #{s.runs}): #{Enum.join(variant, " › ")}
      e.g. #{Enum.map_join(s.examples, ", ", &inspect/1)}
    """
  end

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"
end
