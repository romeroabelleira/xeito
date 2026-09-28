defmodule Mix.Tasks.Xeito.Log do
  @shortdoc "Lists or prunes the sessions in a workspace log"
  @moduledoc """
  Inspects and prunes a workspace's event log (`<workspace>/.xeito/log.sqlite`).

      mix xeito.log sessions [--cwd DIR]
      mix xeito.log prune [--cwd DIR] [--older-than DAYS] [--keep N] [--apply]

  `sessions` lists every session with its status (`open`, `closed`, `interrupted`), last
  activity, runs and events.

  `prune` deletes whole sessions (every run, event and relation under them) and compacts the
  file (`Xeito.Log.Retention`):

    * only `closed` and `interrupted` sessions; `open` ones may be in use and are never touched
    * `--older-than DAYS`: last activity more than DAYS ago
    * `--keep N`: never the N most recently active sessions
    * at least one of the two is required; with both, a session must satisfy both

  **It is a dry run unless `--apply` is given.** Nothing is ever pruned automatically: the log is
  also the data for resume, `/why`, process mining and training deciders.
  """

  use Mix.Task

  alias Exqlite.Sqlite3
  alias Xeito.Log.Retention

  @switches [cwd: :string, older_than: :integer, keep: :integer, apply: :boolean]

  @impl true
  def run(args) do
    {opts, command, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("compile")
    path = Path.join([Path.expand(opts[:cwd] || "."), ".xeito", "log.sqlite"])
    unless File.exists?(path), do: Mix.raise("no log at #{path}")

    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.set_busy_timeout(db, 10_000)

    try do
      case command do
        ["sessions"] -> list(db)
        ["prune"] -> prune(db, path, opts)
        _ -> Mix.raise("usage: mix xeito.log sessions|prune [options]; see `mix help xeito.log`")
      end
    after
      Sqlite3.close(db)
    end
  end

  defp list(db) do
    sessions = Retention.sessions(db)
    Mix.shell().info(header())
    Enum.each(sessions, &Mix.shell().info(row(&1)))
    Mix.shell().info("#{length(sessions)} sessions")
  end

  defp prune(db, path, opts) do
    if opts[:older_than] == nil and opts[:keep] == nil,
      do: Mix.raise("prune needs --older-than DAYS and/or --keep N")

    plan = Retention.plan(db, older_than_days: opts[:older_than], keep: opts[:keep])
    events = plan |> Enum.map(& &1.events) |> Enum.sum()

    Mix.shell().info(header())
    Enum.each(plan, &Mix.shell().info(row(&1)))
    Mix.shell().info("#{length(plan)} sessions, #{events} events to delete")

    cond do
      plan == [] ->
        :ok

      not Keyword.get(opts, :apply, false) ->
        Mix.shell().info("dry run: nothing deleted; add --apply to delete")

      true ->
        before = File.stat!(path).size
        {:ok, result} = Retention.prune(db, plan)
        size = File.stat!(path).size

        Mix.shell().info(
          "deleted #{result.sessions} sessions (#{result.events} events); " <>
            "log #{mb(before)} → #{mb(size)} MB" <>
            if(result.vacuumed,
              do: "",
              else: " (not compacted: the log is busy; run again later)"
            )
        )
    end
  end

  defp header,
    do:
      String.pad_trailing("session", 22) <>
        String.pad_trailing("status", 13) <> "last activity (UTC)  runs  events"

  defp row(s) do
    String.pad_trailing(s.id, 22) <>
      String.pad_trailing(s.status, 13) <>
      String.pad_trailing(s.last |> String.slice(0, 19) |> String.replace("T", " "), 21) <>
      String.pad_trailing("#{s.runs}", 6) <> "#{s.events}"
  end

  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)
end
