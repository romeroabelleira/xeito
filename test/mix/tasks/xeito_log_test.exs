defmodule Mix.Tasks.Xeito.LogTest do
  # Uses the shared workspace-log supervisor and Mix's shell.
  use Xeito.Case, async: false

  alias Exqlite.Sqlite3
  alias Mix.Tasks.Xeito.Log, as: Task
  alias Xeito.Machines.RunTests
  alias Xeito.Session

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-logtask-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    # One closed session with one finished run.
    id = "ses-lt-#{System.unique_integer([:positive])}"
    {:ok, ^id} = Session.start(cwd: ws, id: id)
    Session.subscribe(id)
    :ok = Session.prompt(id, "/run true")
    assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
    [{pid, _}] = Registry.lookup(Xeito.SessionRegistry, id)
    DynamicSupervisor.terminate_child(Xeito.SessionSupervisor, pid)

    %{ws: ws, id: id}
  end

  defp run(ws, args) do
    Task.run(args ++ ["--cwd", ws])
    output()
  end

  defp output(acc \\ "") do
    receive do
      {:mix_shell, :info, [line]} -> output(acc <> line <> "\n")
    after
      0 -> acc
    end
  end

  test "sessions lists every session with its status", %{ws: ws, id: id} do
    out = run(ws, ["sessions"])
    assert out =~ ~r/^#{id}\s+closed\s+\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\s+1\s+\d+$/m
    assert out =~ "1 sessions"
  end

  test "stats shows the bytes per table and per event type", %{ws: ws} do
    out = run(ws, ["stats"])
    assert out =~ "KiB"
    assert out =~ ~r/^run_started\s+1\s+\d+$/m
    assert out =~ ~r/stored messages: \d+/
  end

  test "verify replays every run exactly", %{ws: ws} do
    assert run(ws, ["verify"]) =~ "1 runs: 1 replay exactly, 0 skipped (machine changed since), 0 failed"
  end

  test "verify leaves out the streams that are not runs, such as the written skill examples", %{ws: ws} do
    attrs = %{skill: "s", count: 1}
    event = Xeito.Log.Event.new("skill_examples_generated", {:skill_examples_generated, attrs}, attrs)
    {:ok, _} = ws |> Xeito.Log.for_workspace() |> Xeito.Log.append("skills/examples", [event])

    assert run(ws, ["verify"]) =~ "1 runs: 1 replay exactly, 0 skipped (machine changed since), 0 failed"
  end

  test "verify fails on a run that does not replay", %{ws: ws} do
    {:ok, db} = Sqlite3.open(Path.join([ws, ".xeito", "log.sqlite"]))

    :ok =
      Sqlite3.execute(
        db,
        "INSERT INTO xeito_term (ocel_id, run_id, seq, type, term) " <>
          "VALUES ('broken:1', 'broken', 1, 'transition', x'#{Base.encode16(:erlang.term_to_binary(:nothing))}')"
      )

    Sqlite3.close(db)

    assert_raise Mix.Error, "verify found runs that do not replay", fn -> run(ws, ["verify"]) end
    assert output() =~ "broken: {:error, :no_run_started}"
  end

  # A run written straight into the log, as plain terms (older logs store them so).
  defp put_run(ws, run, terms) do
    {:ok, db} = Sqlite3.open(Path.join([ws, ".xeito", "log.sqlite"]))

    for {term, seq} <- Enum.with_index(terms, 1) do
      type = term |> elem(0) |> Atom.to_string()
      blob = Base.encode16(:erlang.term_to_binary(term))

      :ok =
        Sqlite3.execute(
          db,
          "INSERT INTO xeito_term (ocel_id, run_id, seq, type, term) VALUES ('#{run}:#{seq}', '#{run}', #{seq}, '#{type}', x'#{blob}')"
        )
    end

    Sqlite3.close(db)
  end

  test "verify skips runs of a machine that changed or is gone, and fails on a run that desyncs", %{ws: ws} do
    put_run(ws, "gone", [{:run_started, Xeito.NoSuchMachine, "1.0.0", %{}}])
    put_run(ws, "old", [{:run_started, RunTests, "0.0.0", %{cwd: "/w"}}])
    assert run(ws, ["verify"]) =~ "3 runs: 1 replay exactly, 2 skipped (machine changed since), 0 failed"

    wrong = Xeito.Effect.bash("not the test command", cwd: "/w")

    put_run(ws, "desync", [
      {:run_started, RunTests, "0.1.0", %{cwd: "/w", test_cmd: "mix test"}},
      {:effect_requested, %{wrong | id: "desync/e1"}}
    ])

    assert_raise Mix.Error, "verify found runs that do not replay", fn -> run(ws, ["verify"]) end
    assert output() =~ "desync: {:desync, \"desync/e1\"}"
  end

  test "compact rewrites every run and reports the size", %{ws: ws} do
    assert run(ws, ["compact"]) =~ ~r/^rewrote 1 runs \(\d+ unreferenced messages swept\); log [\d.]+ → [\d.]+ MB/m
    assert run(ws, ["verify"]) =~ "1 replay exactly"
  end

  test "prune is a dry run unless applied, and needs a limit", %{ws: ws, id: id} do
    assert_raise Mix.Error, "prune needs --older-than DAYS and/or --keep N", fn -> run(ws, ["prune"]) end
    assert run(ws, ["prune", "--keep", "5"]) =~ "0 sessions, 0 events to delete"

    dry = run(ws, ["prune", "--keep", "0"])
    assert dry =~ id and dry =~ "dry run: nothing deleted; add --apply to delete"

    assert run(ws, ["prune", "--keep", "0", "--apply"]) =~ ~r/^deleted 1 sessions \(\d+ events, \d+ stored messages\)/m
    assert run(ws, ["sessions"]) =~ "0 sessions"
  end

  test "prune also drops the pruned sessions' undo steps", %{ws: ws, id: id} do
    Xeito.Undo.step(ws, "#{id}/t9/e1", "write a.txt", fn -> File.write!(Path.join(ws, "a.txt"), "a\n") end)
    assert [_] = Xeito.Undo.steps(ws, id)

    run(ws, ["prune", "--keep", "0"])
    assert [_] = Xeito.Undo.steps(ws, id)

    run(ws, ["prune", "--keep", "0", "--apply"])
    assert Xeito.Undo.steps(ws, id) == []
  end

  test "an unknown command, or a workspace without a log, is an error", %{ws: ws} do
    assert_raise Mix.Error, ~r/^usage: mix xeito.log/, fn -> run(ws, ["fly"]) end
    assert_raise Mix.Error, ~r/^no log at /, fn -> run(Path.join(ws, "nowhere"), ["sessions"]) end
  end
end
