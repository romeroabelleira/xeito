defmodule Xeito.Log.Retention do
  @moduledoc """
  Explicit retention for a workspace log: deletes whole sessions (the session, every run under
  it, their events, effects and relations) and compacts the file. Nothing is deleted
  automatically; the log is also the data for resume, `/why`, `/machines`, process mining and
  training deciders. See `mix xeito.log`.

  * Only sessions recorded as `closed` or `interrupted` are candidates. An `open` session may be
    in use by a running daemon and is never touched.
  * `:older_than_days` keeps sessions active within that many days; `:keep` keeps that many of
    the most recently active sessions. With both, a session must satisfy both to be deleted.
  * Runs that belong to no session (scripts, benchmarks) and machine definitions are kept.

  Works on its own SQLite connection, so it can run while the daemon holds the log (SQLite
  locks); compacting (`VACUUM`) may then be postponed, which `prune/2` reports.
  """

  alias Exqlite.Sqlite3
  alias Xeito.Log.Schema

  @type session :: %{
          id: String.t(),
          status: String.t(),
          last: String.t(),
          runs: non_neg_integer(),
          events: non_neg_integer()
        }

  @doc "The sessions of the log with their latest status, last activity, runs and events."
  @spec sessions(Sqlite3.db()) :: [session()]
  def sessions(db) do
    # Activity is a session being opened (or resumed) and its runs; status changes are not
    # (closing, or being marked interrupted later, must not make a session look recent).
    sql = """
    SELECT s.ocel_id,
      (SELECT s2.status FROM object_session s2
        WHERE s2.ocel_id = s.ocel_id AND s2.status IS NOT NULL ORDER BY s2.rowid DESC LIMIT 1),
      MAX(CASE WHEN s.ocel_changed_field IS NULL THEN s.ocel_time END)
    FROM object_session s GROUP BY s.ocel_id
    """

    for [id, status, session_time] <- select(db, sql) do
      [[runs, last_run]] =
        select(
          db,
          "SELECT COUNT(DISTINCT ocel_id), MAX(ocel_time) FROM object_run WHERE #{prefix("ocel_id")}",
          [id]
        )

      [[events]] = select(db, "SELECT COUNT(*) FROM xeito_term WHERE #{prefix("run_id")}", [id])

      %{
        id: id,
        status: status || "open",
        last: Enum.max([session_time, last_run || session_time]),
        runs: runs,
        events: events
      }
    end
    |> Enum.sort_by(& &1.last, :desc)
  end

  @doc "The sessions `prune/2` would delete, newest first. Options: `:older_than_days`, `:keep`, `:now`."
  @spec plan(Sqlite3.db(), keyword()) :: [session()]
  def plan(db, opts) do
    all = sessions(db)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    kept_newest =
      case opts[:keep] do
        nil -> []
        n -> all |> Enum.take(n) |> Enum.map(& &1.id)
      end

    Enum.filter(all, fn s ->
      s.status in ["closed", "interrupted"] and s.id not in kept_newest and
        old_enough?(s, opts[:older_than_days], now)
    end)
  end

  defp old_enough?(_session, nil, _now), do: true

  defp old_enough?(session, days, now) do
    {:ok, last, _} = DateTime.from_iso8601(session.last)
    DateTime.diff(now, last, :second) > days * 86_400
  end

  @doc """
  Deletes the given sessions, one transaction each, then tries to compact the file. Returns
  `{:ok, %{sessions: n, events: n, vacuumed: boolean}}`.
  """
  @spec prune(Sqlite3.db(), [session()]) :: {:ok, map()}
  def prune(db, sessions) do
    Enum.each(sessions, &delete_session(db, &1.id))
    # In WAL mode the compacted pages land in the WAL file; the checkpoint moves them into the
    # log file and truncates the WAL, so the file actually shrinks now.
    vacuumed =
      Sqlite3.execute(db, "VACUUM") == :ok and
        Sqlite3.execute(db, "PRAGMA wal_checkpoint(TRUNCATE)") == :ok

    {:ok,
     %{
       sessions: length(sessions),
       events: Enum.sum(Enum.map(sessions, & &1.events)),
       vacuumed: vacuumed
     }}
  end

  defp delete_session(db, id) do
    events = "SELECT ocel_id FROM xeito_term WHERE #{prefix("run_id")}"

    statements =
      for(
        type <- Map.keys(Schema.event_types()),
        do: "DELETE FROM event_#{type} WHERE ocel_id IN (#{events})"
      ) ++
        [
          "DELETE FROM event_object WHERE ocel_event_id IN (#{events})",
          "DELETE FROM event WHERE ocel_id IN (#{events})",
          "DELETE FROM xeito_term WHERE #{prefix("run_id")}",
          "DELETE FROM object_object WHERE #{prefix("ocel_source_id")} OR #{prefix("ocel_target_id")}"
        ] ++
        for(
          type <- Map.keys(Schema.object_types()),
          do: "DELETE FROM object_#{type} WHERE #{prefix("ocel_id")}"
        ) ++
        ["DELETE FROM object WHERE #{prefix("ocel_id")}"]

    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    try do
      Enum.each(statements, &run(db, &1, [id]))
      :ok = Sqlite3.execute(db, "COMMIT")
    rescue
      e ->
        Sqlite3.execute(db, "ROLLBACK")
        reraise e, __STACKTRACE__
    end
  end

  # The id itself, or anything under it (`<id>/…`): runs, effects, escalations, delegations.
  defp prefix(column),
    do: "(#{column} = ?1 OR substr(#{column}, 1, length(?1) + 1) = ?1 || '/')"

  defp run(db, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(stmt, params)
    :done = Sqlite3.step(db, stmt)
    :ok = Sqlite3.release(db, stmt)
  end

  defp select(db, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    :ok = Sqlite3.bind(stmt, params)
    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    :ok = Sqlite3.release(db, stmt)
    rows
  end
end
