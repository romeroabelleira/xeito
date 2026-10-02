defmodule Xeito.Log do
  @moduledoc """
  Append-only OCEL 2.0 event log in SQLite. It is the single source of truth for runs.

  One process owns the connection (a single writer, WAL mode). `append/3` is synchronous:
  it returns only after the events are committed. A run acknowledges a state change only after
  the change is logged (invariant 1 in `docs/architecture/02-state-machine-core.md`).

  Every event gets a per-run sequence number, an OCEL id `"<run_id>:<seq>"`, a UTC timestamp,
  its typed OCEL attributes, an `event_object` link to its run (qualifier `"within"`) plus any
  extra objects, and the exact term in `xeito_term` for replay. Terms and attributes are stored
  compactly (message chains stored once, results not repeated, compression; `Xeito.Log.Store`),
  and read back exactly.

  See `docs/architecture/05-event-log-and-process-mining.md`.
  """

  use GenServer

  alias Exqlite.Sqlite3
  # --- Client API --------------------------------------------------------------------------
  alias Xeito.Log.Codec
  alias Xeito.Log.Event
  alias Xeito.Log.Schema
  alias Xeito.Log.Sql
  alias Xeito.Log.Store

  @type server :: GenServer.server()

  @doc """
  Starts a log. Options: `:path` (required), `:name`, `:idle_ms` (stop after that long without a
  call; workspace logs), `:reconcile` (on open, mark sessions left `open` by an earlier daemon as
  `interrupted`; workspace logs).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, {path, opts}, Keyword.take(opts, [:name]))
  end

  @doc """
  The log of a workspace, `<cwd>/.xeito/log.sqlite`, started on first use under
  `Xeito.WorkspaceLogs` and registered by path. Sessions started by the daemon use it, so each
  project keeps its own log (`docs/architecture/07-harness-frontend.md#context-and-configuration`).

  A workspace log closes itself after `config :xeito, :log_idle_ms` (default 30 minutes)
  without a call, so a daemon that touched many projects does not keep them all open. Callers
  keep the returned name; the next call reopens the log transparently (see `call/2`).
  """
  @spec for_workspace(Path.t()) :: server()
  def for_workspace(cwd) do
    dir = cwd |> Path.expand() |> Path.join(".xeito")
    path = Path.join(dir, "log.sqlite")

    # The workspace log is the user's data, never the project's: keep it out of version control.
    File.mkdir_p!(dir)
    ignore = Path.join(dir, ".gitignore")
    if !File.exists?(ignore), do: File.write!(ignore, "*\n")
    open_workspace(path)
  end

  defp open_workspace(path) do
    name = {:via, Registry, {Xeito.LogRegistry, path}}
    idle = Application.get_env(:xeito, :log_idle_ms, 1_800_000)

    spec =
      Supervisor.child_spec(
        {__MODULE__,
         path: path, name: name, idle_ms: idle, reconcile: true, workspace: path |> Path.dirname() |> Path.dirname()},
        restart: :transient
      )

    case DynamicSupervisor.start_child(Xeito.WorkspaceLogs, spec) do
      {:ok, _} -> name
      {:error, {:already_started, _}} -> name
    end
  end

  # A workspace log that closed while idle is reopened on its next call. Other logs (the
  # default log, test logs) are plain GenServer calls.
  defp call({:via, Registry, {Xeito.LogRegistry, path}} = name, request) do
    GenServer.call(name, request)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] ->
      open_workspace(path)
      GenServer.call(name, request)
  end

  defp call(log, request), do: GenServer.call(log, request)

  @doc "Appends events for `run_id` in one transaction. Returns their sequence numbers."
  @spec append(server(), String.t(), [Event.t()]) :: {:ok, [pos_integer()]}
  def append(log, run_id, events), do: call(log, {:append, run_id, events})

  # --- Server ------------------------------------------------------------------------------

  @doc "Records an object (or a change of its attributes). `changed` names the changed field, if any."
  @spec put_object(server(), String.t(), String.t(), map(), String.t() | nil) :: :ok
  def put_object(log, id, type, attrs, changed \\ nil), do: call(log, {:put_object, id, type, attrs, changed})

  @doc "Relates two objects (`object_object`)."
  @spec relate(server(), String.t(), String.t(), String.t()) :: :ok
  def relate(log, source, target, qualifier), do: call(log, {:relate, source, target, qualifier})

  @doc "All events of a run, in order: `[{seq, type, term}]`."
  @spec read_run(server(), String.t()) :: [{pos_integer(), String.t(), term()}]
  def read_run(log, run_id), do: call(log, {:read_run, run_id})

  @doc "Runs a read-only SQL query and returns the rows (for tests, exports and diagnostics)."
  @spec query(server(), String.t(), list()) :: [list()]
  def query(log, sql, params \\ []), do: call(log, {:query, sql, params})

  @impl true
  def init({path, opts}) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(db, "PRAGMA synchronous=NORMAL")
    :ok = Sqlite3.set_busy_timeout(db, 5_000)
    Enum.each(Schema.statements(), &(:ok = Sqlite3.execute(db, &1)))
    :ok = Store.prepare(db)
    if opts[:reconcile], do: reconcile_sessions(db)

    state = %{
      db: db,
      seqs: %{},
      idle: Keyword.get(opts, :idle_ms) || :infinity,
      workspace: opts[:workspace],
      check: Application.get_env(:xeito, :check_log_roundtrip, false)
    }

    {:ok, state, state.idle}
  end

  @impl true
  # Closing an idle workspace log is also when its undo store is tidied (`Xeito.Undo.gc/1`).
  def handle_info(:timeout, %{workspace: nil} = state), do: {:stop, :normal, state}

  def handle_info(:timeout, state) do
    Xeito.Undo.gc(state.workspace)
    {:stop, :normal, state}
  end

  # Sessions recorded as open whose process is not alive in this daemon ended without closing
  # (the daemon stopped abruptly): record that, so the log does not claim they are open.
  defp reconcile_sessions(db) do
    sql = """
    SELECT s.ocel_id FROM object_session s
    WHERE s.status = 'open' AND s.rowid = (
      SELECT MAX(s2.rowid) FROM object_session s2 WHERE s2.ocel_id = s.ocel_id AND s2.status IS NOT NULL)
    """

    for [id] <- select(db, sql, []), not live_session?(id) do
      write_object(db, id, "session", %{status: "interrupted"}, "status")
    end
  end

  defp live_session?(id),
    do: Process.whereis(Xeito.SessionRegistry) != nil and Registry.lookup(Xeito.SessionRegistry, id) != []

  @impl true
  def handle_call({:append, run_id, events}, _from, state) do
    {next, state} = next_seq(state, run_id)
    time = DateTime.to_iso8601(DateTime.utc_now())

    seqs =
      transaction(state.db, fn ->
        numbered = events |> Enum.with_index(next) |> Enum.map(fn {e, seq} -> {seq, e} end)

        for {seq, event, blob, heads} <- Store.encode(state.db, run_id, numbered) do
          insert_event(state.db, run_id, seq, time, event, blob)
          Store.put_refs(state.db, "#{run_id}:#{seq}", heads)
          seq
        end
      end)

    if state.check, do: check_roundtrip!(state.db, run_id, seqs, events)
    state = %{state | seqs: Map.put(state.seqs, run_id, next + length(events))}
    {:reply, {:ok, seqs}, state, state.idle}
  end

  def handle_call({:put_object, id, type, attrs, changed}, _from, state) do
    write_object(state.db, id, type, attrs, changed)
    {:reply, :ok, state, state.idle}
  end

  def handle_call({:relate, source, target, qualifier}, _from, state) do
    exec(
      state.db,
      "INSERT OR IGNORE INTO object_object (ocel_source_id, ocel_target_id, ocel_qualifier) VALUES (?1, ?2, ?3)",
      # --- SQL helpers -------------------------------------------------------------------------
      [source, target, qualifier]
    )

    {:reply, :ok, state, state.idle}
  end

  def handle_call({:read_run, run_id}, _from, state) do
    rows =
      select(state.db, "SELECT seq, type, term FROM xeito_term WHERE run_id = ?1 ORDER BY seq", [
        run_id
      ])

    {:reply, Store.decode(state.db, rows), state, state.idle}
  end

  def handle_call({:query, sql, params}, _from, state) do
    {:reply, select(state.db, sql, params), state, state.idle}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.db)

  # Reads the rows just written back and compares them with the appended events (tests).
  defp check_roundtrip!(db, run_id, seqs, events) do
    rows =
      select(
        db,
        "SELECT seq, type, term FROM xeito_term WHERE run_id = ?1 AND seq >= ?2 ORDER BY seq",
        [run_id, List.first(seqs)]
      )

    expected = Enum.zip_with(seqs, events, &{&1, &2.type, &2.term})

    if Store.decode(db, rows) != expected,
      do: raise("log round trip failed for #{run_id} #{inspect(seqs)}")
  end

  defp write_object(db, id, type, attrs, changed) do
    columns = Map.fetch!(Schema.object_types(), type)
    time = DateTime.to_iso8601(DateTime.utc_now())

    transaction(db, fn ->
      exec(db, "INSERT OR IGNORE INTO object (ocel_id, ocel_type) VALUES (?1, ?2)", [id, type])
      attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      values = Enum.map(columns, &Codec.attr(Map.get(attrs, &1)))

      insert_row(
        db,
        "object_#{type}",
        ["ocel_id", "ocel_time", "ocel_changed_field" | columns],
        [id, time, changed | values]
      )
    end)
  end

  defp next_seq(state, run_id) do
    case state.seqs do
      %{^run_id => seq} ->
        {seq, state}

      _ ->
        [[max]] =
          select(state.db, "SELECT COALESCE(MAX(seq), 0) FROM xeito_term WHERE run_id = ?1", [
            run_id
          ])

        {max + 1, %{state | seqs: Map.put(state.seqs, run_id, max + 1)}}
    end
  end

  defp insert_event(db, run_id, seq, time, %Event{} = event, blob) do
    id = "#{run_id}:#{seq}"
    columns = Map.fetch!(Schema.event_types(), event.type)
    values = Enum.map(columns, &Codec.attr(Map.get(event.attrs, &1)))

    exec(db, "INSERT INTO event (ocel_id, ocel_type) VALUES (?1, ?2)", [id, event.type])
    insert_row(db, "event_#{event.type}", ["ocel_id", "ocel_time" | columns], [id, time | values])

    for {object_id, type, qualifier} <- [{run_id, "run", "within"} | event.objects] do
      ensure_object(db, object_id, type, time, event.attrs)

      exec(
        db,
        "INSERT OR IGNORE INTO event_object (ocel_event_id, ocel_object_id, ocel_qualifier) VALUES (?1, ?2, ?3)",
        [id, object_id, qualifier]
      )
    end

    exec(
      db,
      "INSERT INTO xeito_term (ocel_id, run_id, seq, type, term) VALUES (?1, ?2, ?3, ?4, ?5)",
      [id, run_id, seq, event.type, {:blob, blob}]
    )
  end

  defp ensure_object(db, id, type, time, attrs) do
    exec(db, "INSERT OR IGNORE INTO object (ocel_id, ocel_type) VALUES (?1, ?2)", [id, type])

    if Sqlite3.changes(db) in [1, {:ok, 1}] do
      columns = Map.fetch!(Schema.object_types(), type)
      values = Enum.map(columns, &Codec.attr(Map.get(attrs, &1)))

      insert_row(db, "object_#{type}", ["ocel_id", "ocel_time", "ocel_changed_field" | columns], [
        id,
        time,
        nil | values
      ])
    end
  end

  defp insert_row(db, table, columns, values) do
    placeholders = Enum.map_join(1..length(columns), ", ", &"?#{&1}")

    exec(
      db,
      "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders})",
      values
    )
  end

  defp transaction(db, fun), do: Sql.transaction(db, fun)
  defp exec(db, sql, params), do: Sql.exec(db, sql, params)
  defp select(db, sql, params), do: Sql.select(db, sql, params)
end
