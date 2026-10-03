defmodule Mix.Tasks.Xeito.Log do
  @shortdoc "Inspects, verifies, compacts or prunes a workspace log"
  @moduledoc """
  Inspects and maintains a workspace's event log (`<workspace>/.xeito/log.sqlite`).

      mix xeito.log sessions [--cwd DIR]
      mix xeito.log stats [--cwd DIR]
      mix xeito.log verify [--cwd DIR]
      mix xeito.log compact [--cwd DIR]
      mix xeito.log prune [--cwd DIR] [--older-than DAYS] [--keep N] [--apply]

  `sessions` lists every session with its status (`open`, `closed`, `interrupted`), last
  activity, runs and events.

  `stats` shows where the bytes are: per table, and per event type for the stored terms.

  `verify` replays every run from the log (`Xeito.Run.Recovery`) and checks that the replay
  requests exactly the effects the log recorded, for chat calls the exact messages the model
  saw. Runs of a machine version that is no longer the current one are skipped.

  `compact` rewrites events stored before the compact layout (`Xeito.Log.Store`: message chains
  stored once, results not repeated, compressed terms), then compacts the file. Old logs read fine
  without it; it only saves space. Stop the daemon first, or run it on a copy.

  `prune` deletes whole sessions (every run, event and relation under them) and compacts the
  file (`Xeito.Log.Retention`):

    * only `closed` and `interrupted` sessions; `open` ones may be in use and are never touched
    * `--older-than DAYS`: last activity more than DAYS ago
    * `--keep N`: never the N most recently active sessions
    * at least one of the two is required; with both, a session must satisfy both
    * the deleted sessions' undo steps go with them (`Xeito.Undo.forget/2`), and file versions
      no step holds any more are freed

  **It is a dry run unless `--apply` is given.** Nothing is ever pruned automatically: the log is
  also the data for resume, `/why`, process mining and training deciders.
  """

  use Mix.Task

  alias Exqlite.Sqlite3
  alias Xeito.Log.Codec
  alias Xeito.Log.Event
  alias Xeito.Log.Retention
  alias Xeito.Log.Sql
  alias Xeito.Log.Store
  alias Xeito.Run.Recovery

  @switches [cwd: :string, older_than: :integer, keep: :integer, apply: :boolean]

  @impl true
  def run(args) do
    {opts, command, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("compile")
    path = Path.join([Path.expand(opts[:cwd] || "."), ".xeito", "log.sqlite"])
    if !File.exists?(path), do: Mix.raise("no log at #{path}")

    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.set_busy_timeout(db, 10_000)
    # The same idempotent setup (and migration) the daemon runs when it opens a log.
    :ok = Store.prepare(db)

    try do
      dispatch(command, db, path, opts)
    after
      Sqlite3.close(db)
    end
  end

  defp dispatch(["sessions"], db, _path, _opts), do: list(db)
  defp dispatch(["stats"], db, path, _opts), do: stats(db, path)
  defp dispatch(["verify"], db, _path, _opts), do: verify(db)
  defp dispatch(["compact"], db, path, _opts), do: compact(db, path)
  defp dispatch(["prune"], db, path, opts), do: prune(db, path, opts)

  defp dispatch(_command, _db, _path, _opts),
    do: Mix.raise("usage: mix xeito.log sessions|stats|verify|compact|prune; see `mix help xeito.log`")

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

      # --- stats ---------------------------------------------------------------------------------
      true ->
        before = File.stat!(path).size
        {:ok, result} = Retention.prune(db, plan)
        workspace = path |> Path.dirname() |> Path.dirname()
        Enum.each(plan, &Xeito.Undo.forget(workspace, &1.id))
        Xeito.Undo.gc(workspace)
        size = File.stat!(path).size

        Mix.shell().info(
          "deleted #{result.sessions} sessions (#{result.events} events, " <>
            "#{result.messages} stored messages); " <>
            "log #{mb(before)} → #{mb(size)} MB" <>
            if(result.vacuumed,
              do: "",
              else: " (not compacted: the log is busy; run again later)"
            )
        )
    end
  end

  defp stats(db, path) do
    Mix.shell().info("#{path}: #{kib(File.stat!(path).size)} KiB\n")
    Mix.shell().info(String.pad_trailing("table or index", 36) <> "KiB")

    for [name, bytes] <-
          Sql.select(db, "SELECT name, SUM(pgsize) FROM dbstat GROUP BY name ORDER BY 2 DESC") do
      Mix.shell().info(String.pad_trailing(name, 36) <> kib(bytes))
    end

    Mix.shell().info("\n" <> String.pad_trailing("stored terms by event type", 26) <> "events  KiB")

    for [type, n, bytes] <-
          Sql.select(
            db,
            # --- verify --------------------------------------------------------------------------------
            "SELECT type, COUNT(*), SUM(length(term)) FROM xeito_term GROUP BY type ORDER BY 3 DESC"
          ) do
      Mix.shell().info(String.pad_trailing(type, 26) <> String.pad_trailing("#{n}", 8) <> kib(bytes))
    end

    [[n, bytes]] =
      Sql.select(
        db,
        "SELECT COUNT(*), COALESCE(SUM(length(json)), 0) + COALESCE(SUM(length(term)), 0) FROM xeito_message"
      )

    Mix.shell().info("\nstored messages: #{n} (#{kib(bytes)} KiB)")
  end

  defp verify(db) do
    results = for run <- runs(db), do: {run, verify_run(db, run)}

    for {run, result} <- results, result not in [:ok, :skipped] do
      Mix.shell().info("#{run}: #{inspect(result)}")
    end

    counts = Enum.frequencies_by(results, fn {_, r} -> if is_atom(r), do: r, else: :failed end)

    Mix.shell().info(
      "#{length(results)} runs: #{counts[:ok] || 0} replay exactly, " <>
        "#{counts[:skipped] || 0} skipped (machine changed since), #{counts[:failed] || 0} failed"
    )

    if counts[:failed], do: Mix.raise("verify found runs that do not replay")
  end

  defp verify_run(db, run) do
    case read_run(db, run) do
      [{_, "run_started", {:run_started, module, _version, _input}} | _] = entries ->
        replay(module, entries)

      _ ->
        {:error, :no_run_started}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp replay(module, entries) do
    if Code.ensure_loaded?(module) do
      case Recovery.rebuild(module, entries) do
        {:ok, %{desync: nil}} -> :ok
        {:ok, %{desync: id}} -> {:desync, id}
        {:error, {:version_mismatch, _}} -> :skipped
        {:error, reason} -> {:error, reason}
      end
    else
      :skipped
    end
  end

  # --- compact -------------------------------------------------------------------------------

  # The event attributes that carry payloads, rebuilt from the exact term.
  @payloads %{
    "effect_requested" => "args",
    "effect_completed" => "result",
    "event_received" => "data",
    "run_started" => "input"
  }

  defp compact(db, path) do
    before = File.stat!(path).size
    runs = runs(db)
    Enum.each(runs, &compact_run(db, &1))
    swept = Store.sweep(db)

    vacuumed =
      Sqlite3.execute(db, "VACUUM") == :ok and
        Sqlite3.execute(db, "PRAGMA wal_checkpoint(TRUNCATE)") == :ok

    Mix.shell().info(
      "rewrote #{length(runs)} runs (#{swept} unreferenced messages swept); " <>
        "log #{mb(before)} → #{mb(File.stat!(path).size)} MB" <>
        if(vacuumed, do: "", else: " (not compacted: the log is busy; run again later)")
    )
  end

  defp compact_run(db, run) do
    Sql.transaction(db, fn ->
      events =
        for {seq, type, term} <- read_run(db, run),
            do: {seq, Event.new(type, term, payload(type, term))}

      Sql.exec(
        db,
        "DELETE FROM xeito_term_chain WHERE ocel_id IN " <>
          "(SELECT ocel_id FROM xeito_term WHERE run_id = ?1)",
        [run]
      )

      for encoded <- Store.encode(db, run, events), do: rewrite(db, run, encoded)
    end)
  end

  defp rewrite(db, run, {seq, event, blob, heads}) do
    id = "#{run}:#{seq}"
    Sql.exec(db, "UPDATE xeito_term SET term = ?1 WHERE ocel_id = ?2", [{:blob, blob}, id])
    # --- helpers -------------------------------------------------------------------------------
    Store.put_refs(db, id, heads)

    for {column, value} <- event.attrs do
      Sql.exec(db, "UPDATE event_#{event.type} SET #{column} = ?1 WHERE ocel_id = ?2", [
        Codec.attr(value),
        id
      ])
    end
  end

  defp payload(type, term) do
    case {Map.fetch(@payloads, type), term} do
      {{:ok, col}, {:effect_requested, effect}} -> %{col => effect.args}
      {{:ok, col}, {:effect_completed, _id, result}} -> %{col => result}
      {{:ok, col}, {:event, _name, data, _actor}} -> %{col => data}
      {{:ok, col}, {:run_started, _module, _version, input}} -> %{col => input}
      _ -> %{}
    end
  end

  # The runs' event streams. A session's own stream (its typed and queued prompts, undo steps)
  # is not a run: nothing replays it, and its events are small plain terms.
  defp runs(db) do
    sql =
      "SELECT DISTINCT run_id FROM xeito_term WHERE run_id NOT IN (SELECT ocel_id FROM object_session) ORDER BY run_id"

    for [run] <- Sql.select(db, sql), do: run
  end

  # Plain terms (older logs) have no chain references, so they decode without the store tables.
  defp read_run(db, run) do
    Store.decode(
      db,
      Sql.select(db, "SELECT seq, type, term FROM xeito_term WHERE run_id = ?1 ORDER BY seq", [
        run
      ])
    )
  end

  defp kib(bytes), do: "#{div(bytes || 0, 1024)}"

  defp header,
    do: String.pad_trailing("session", 22) <> String.pad_trailing("status", 13) <> "last activity (UTC)  runs  events"

  defp row(s) do
    String.pad_trailing(s.id, 22) <>
      String.pad_trailing(s.status, 13) <>
      (s.last |> String.slice(0, 19) |> String.replace("T", " ") |> String.pad_trailing(21)) <>
      String.pad_trailing("#{s.runs}", 6) <> "#{s.events}"
  end

  defp mb(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1)
end
