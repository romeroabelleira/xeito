defmodule Xeito.Log do
  @moduledoc """
  Append-only OCEL 2.0 event log in SQLite. It is the single source of truth for runs.

  One process owns the connection (a single writer, WAL mode). `append/3` is synchronous:
  it returns only after the events are committed. A run acknowledges a state change only after
  the change is logged (invariant 1 in `docs/architecture/02-state-machine-core.md`).

  Every event gets a per-run sequence number, an OCEL id `"<run_id>:<seq>"`, a UTC timestamp,
  its typed OCEL attributes, an `event_object` link to its run (qualifier `"within"`) plus any
  extra objects, and the exact term in `xeito_term` for replay.

  See `docs/architecture/05-event-log-and-process-mining.md`.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias Xeito.Log.{Codec, Event, Schema}

  @type server :: GenServer.server()

  # --- Client API --------------------------------------------------------------------------

  @doc "Starts a log. Options: `:path` (required), `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, path, Keyword.take(opts, [:name]))
  end

  @doc "Appends events for `run_id` in one transaction. Returns their sequence numbers."
  @spec append(server(), String.t(), [Event.t()]) :: {:ok, [pos_integer()]}
  def append(log, run_id, events), do: GenServer.call(log, {:append, run_id, events})

  @doc "Records an object (or a change of its attributes). `changed` names the changed field, if any."
  @spec put_object(server(), String.t(), String.t(), map(), String.t() | nil) :: :ok
  def put_object(log, id, type, attrs, changed \\ nil),
    do: GenServer.call(log, {:put_object, id, type, attrs, changed})

  @doc "Relates two objects (`object_object`)."
  @spec relate(server(), String.t(), String.t(), String.t()) :: :ok
  def relate(log, source, target, qualifier),
    do: GenServer.call(log, {:relate, source, target, qualifier})

  @doc "All events of a run, in order: `[{seq, type, term}]`."
  @spec read_run(server(), String.t()) :: [{pos_integer(), String.t(), term()}]
  def read_run(log, run_id), do: GenServer.call(log, {:read_run, run_id})

  @doc "Runs a read-only SQL query and returns the rows (for tests, exports and diagnostics)."
  @spec query(server(), String.t(), list()) :: [list()]
  def query(log, sql, params \\ []), do: GenServer.call(log, {:query, sql, params})

  # --- Server ------------------------------------------------------------------------------

  @impl true
  def init(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(db, "PRAGMA synchronous=NORMAL")
    :ok = Sqlite3.set_busy_timeout(db, 5_000)
    Enum.each(Schema.statements(), &(:ok = Sqlite3.execute(db, &1)))
    {:ok, %{db: db, seqs: %{}}}
  end

  @impl true
  def handle_call({:append, run_id, events}, _from, state) do
    {next, state} = next_seq(state, run_id)
    time = DateTime.utc_now() |> DateTime.to_iso8601()

    seqs =
      transaction(state.db, fn ->
        events
        |> Enum.with_index(next)
        |> Enum.map(fn {event, seq} ->
          insert_event(state.db, run_id, seq, time, event)
          seq
        end)
      end)

    {:reply, {:ok, seqs}, %{state | seqs: Map.put(state.seqs, run_id, next + length(events))}}
  end

  def handle_call({:put_object, id, type, attrs, changed}, _from, state) do
    columns = Map.fetch!(Schema.object_types(), type)
    time = DateTime.utc_now() |> DateTime.to_iso8601()

    transaction(state.db, fn ->
      exec(state.db, "INSERT OR IGNORE INTO object (ocel_id, ocel_type) VALUES (?1, ?2)", [
        id,
        type
      ])

      attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
      values = Enum.map(columns, &Codec.attr(Map.get(attrs, &1)))

      insert_row(
        state.db,
        "object_#{type}",
        ["ocel_id", "ocel_time", "ocel_changed_field" | columns],
        [id, time, changed | values]
      )
    end)

    {:reply, :ok, state}
  end

  def handle_call({:relate, source, target, qualifier}, _from, state) do
    exec(
      state.db,
      "INSERT OR IGNORE INTO object_object (ocel_source_id, ocel_target_id, ocel_qualifier) VALUES (?1, ?2, ?3)",
      [source, target, qualifier]
    )

    {:reply, :ok, state}
  end

  def handle_call({:read_run, run_id}, _from, state) do
    rows =
      select(state.db, "SELECT seq, type, term FROM xeito_term WHERE run_id = ?1 ORDER BY seq", [
        run_id
      ])

    {:reply,
     Enum.map(rows, fn [seq, type, term] -> {seq, type, :erlang.binary_to_term(term)} end), state}
  end

  def handle_call({:query, sql, params}, _from, state) do
    {:reply, select(state.db, sql, params), state}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.db)

  # --- SQL helpers -------------------------------------------------------------------------

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

  defp insert_event(db, run_id, seq, time, %Event{} = event) do
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
      [id, run_id, seq, event.type, {:blob, :erlang.term_to_binary(event.term)}]
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

  defp transaction(db, fun) do
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      :ok = Sqlite3.execute(db, "COMMIT")
      result
    rescue
      error ->
        Sqlite3.execute(db, "ROLLBACK")
        reraise error, __STACKTRACE__
    end
  end

  defp exec(db, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(stmt, params)
      :done = Sqlite3.step(db, stmt)
      :ok
    after
      Sqlite3.release(db, stmt)
    end
  end

  defp select(db, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(stmt, params)
      {:ok, rows} = Sqlite3.fetch_all(db, stmt)
      rows
    after
      Sqlite3.release(db, stmt)
    end
  end
end
