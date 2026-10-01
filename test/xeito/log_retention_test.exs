defmodule Xeito.LogRetentionTest do
  # Changes application env (log idle time) and uses the shared workspace-log supervisor.
  use Xeito.Case, async: false

  alias Exqlite.Sqlite3
  alias Xeito.Log
  alias Xeito.Log.Retention
  alias Xeito.Machines.RunTests
  alias Xeito.RunSupervisor
  alias Xeito.Session

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-ret-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    %{ws: ws}
  end

  defp path(ws), do: Path.join([ws, ".xeito", "log.sqlite"])
  defp log_pid(ws), do: Registry.lookup(Xeito.LogRegistry, path(ws))

  defp latest_status(log, id) do
    [[status]] =
      Log.query(
        log,
        "SELECT status FROM object_session WHERE ocel_id = ?1 AND status IS NOT NULL ORDER BY rowid DESC LIMIT 1",
        [id]
      )

    status
  end

  defp with_idle(ms) do
    previous = Application.get_env(:xeito, :log_idle_ms)
    Application.put_env(:xeito, :log_idle_ms, ms)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:xeito, :log_idle_ms, previous),
        else: Application.delete_env(:xeito, :log_idle_ms)
    end)
  end

  test "a workspace log closes when idle and reopens on its next call", %{ws: ws} do
    with_idle(50)
    log = Log.for_workspace(ws)
    Log.put_object(log, "ses-a", "session", %{cwd: ws, status: "open"})
    eventually(fn -> log_pid(ws) == [] end)

    # The same name keeps working: the call reopens the log.
    assert [[1]] = Log.query(log, "SELECT COUNT(*) FROM object WHERE ocel_id = 'ses-a'")
    assert [{_, _}] = log_pid(ws)
  end

  test "opening a workspace log marks orphaned open sessions interrupted, never live ones",
       %{ws: ws} do
    with_idle(100)
    log = Log.for_workspace(ws)
    Log.put_object(log, "ses-orphan", "session", %{cwd: ws, status: "open"})

    {:ok, live} = Session.start(cwd: ws, id: "ses-live-#{System.unique_integer([:positive])}")
    eventually(fn -> log_pid(ws) == [] end)

    assert latest_status(log, "ses-orphan") == "interrupted"
    assert latest_status(log, live) == "open"

    # A clean stop records the session closed.
    [{pid, _}] = Registry.lookup(Xeito.SessionRegistry, live)
    DynamicSupervisor.terminate_child(Xeito.SessionSupervisor, pid)
    assert latest_status(log, live) == "closed"
  end

  test "prune deletes whole closed or interrupted sessions and nothing else", %{ws: ws} do
    log = Log.for_workspace(ws)

    session = fn id, status ->
      Log.put_object(log, id, "session", %{cwd: ws, status: "open"})
      if status != "open", do: Log.put_object(log, id, "session", %{status: status}, "status")

      {:ok, run} =
        RunSupervisor.start_run(RunTests, %{cwd: ws},
          run_id: "#{id}/t1",
          log: log,
          runner: scripted_runner([%{exit_status: 0, output: "ok"}])
        )

      await_exit(run)
      Log.relate(log, run, id, "part_of")
    end

    session.("ses-old", "closed")
    session.("ses-crashed", "interrupted")
    session.("ses-newest", "closed")
    session.("ses-open", "open")

    {:ok, other} =
      RunSupervisor.start_run(RunTests, %{cwd: ws},
        run_id: "run-script",
        log: log,
        runner: scripted_runner([%{exit_status: 0, output: "ok"}])
      )

    await_exit(other)

    {:ok, db} = Sqlite3.open(path(ws))
    on_exit(fn -> Sqlite3.close(db) end)

    assert length(Retention.sessions(db)) == 4
    # The two most recently active sessions (ses-open, ses-newest) are kept; an open session is
    # never a candidate anyway.
    plan = Retention.plan(db, keep: 2)
    assert plan |> Enum.map(& &1.id) |> Enum.sort() == ["ses-crashed", "ses-old"]
    assert Retention.plan(db, older_than_days: 1) == []

    # Status changes are not activity: closing a session a year later leaves it a year old.
    {:ok, next_year, _} = DateTime.from_iso8601("#{Date.utc_today().year + 1}-12-31T00:00:00Z")
    assert length(Retention.plan(db, older_than_days: 30, now: next_year)) == 3

    {:ok, %{sessions: 2, events: events}} = Retention.prune(db, plan)
    assert events > 0

    remaining = Log.query(log, "SELECT DISTINCT run_id FROM xeito_term ORDER BY run_id")
    assert remaining == [["run-script"], ["ses-newest/t1"], ["ses-open/t1"]]

    assert [[0]] =
             Log.query(
               log,
               "SELECT COUNT(*) FROM object WHERE ocel_id LIKE 'ses-old%' OR ocel_id LIKE 'ses-crashed%'"
             )

    assert [[0]] =
             Log.query(
               log,
               "SELECT COUNT(*) FROM object_object WHERE ocel_target_id IN ('ses-old', 'ses-crashed')"
             )

    assert [[n]] = Log.query(log, "SELECT COUNT(*) FROM event")
    assert n == length(Log.query(log, "SELECT ocel_id FROM xeito_term"))
  end
end
