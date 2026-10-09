defmodule Xeito.LogTest do
  use Xeito.Case, async: true

  alias Xeito.Log
  alias Xeito.Log.Event

  test "appends events with per-run sequence numbers and reads exact terms back" do
    log = start_log!()

    assert {:ok, [1, 2]} =
             Log.append(log, "r1", [
               Event.new("state_entered", {:state_entered, :a}, %{"state" => :a}),
               Event.new("event_received", {:event, {:decided, :flaky}, %{x: {1, 2}}, :code}, %{
                 "name" => {:decided, :flaky}
               })
             ])

    assert {:ok, [3]} =
             Log.append(log, "r1", [
               Event.new("state_entered", {:state_entered, :b}, %{"state" => :b})
             ])

    assert {:ok, [1]} =
             Log.append(log, "r2", [
               Event.new("state_entered", {:state_entered, :z}, %{"state" => :z})
             ])

    assert [
             {1, "state_entered", {:state_entered, :a}},
             {2, "event_received", {:event, {:decided, :flaky}, %{x: {1, 2}}, :code}},
             {3, "state_entered", {:state_entered, :b}}
           ] = Log.read_run(log, "r1")
  end

  test "keeps the log in WAL mode and syncs every commit to disk" do
    log = start_log!()

    assert [["wal"]] = Log.query(log, "PRAGMA journal_mode")
    # 2 is FULL: a commit survives a power cut, not only a crash.
    assert [[2]] = Log.query(log, "PRAGMA synchronous")
  end

  test "refuses to start when the log cannot use WAL mode" do
    Process.flag(:trap_exit, true)

    # An in-memory database stays in "memory" journal mode whatever is asked for.
    assert {:error, {{:badmatch, [["memory"]]}, _}} = Log.start_link(path: ":memory:")
  end

  test "writes the OCEL 2.0 relational layout" do
    log = start_log!()

    Log.append(log, "r1", [
      Event.new(
        "effect_requested",
        {:effect_requested, :e},
        %{"effect_id" => "r1/e1", "kind" => :bash},
        [
          {"r1/e1", "effect", "of"}
        ]
      )
    ])

    assert [["r1:1", "effect_requested"]] = Log.query(log, "SELECT ocel_id, ocel_type FROM event")

    assert [["r1:1", "r1/e1", "bash"]] =
             Log.query(log, "SELECT ocel_id, effect_id, kind FROM event_effect_requested")

    assert Log.query(
             log,
             "SELECT ocel_event_id, ocel_object_id, ocel_qualifier FROM event_object ORDER BY 2"
           ) ==
             [["r1:1", "r1", "within"], ["r1:1", "r1/e1", "of"]]

    assert Log.query(log, "SELECT ocel_id, ocel_type FROM object ORDER BY 1") == [
             ["r1", "run"],
             ["r1/e1", "effect"]
           ]

    assert [["r1/e1", "bash"]] = Log.query(log, "SELECT ocel_id, kind FROM object_effect")

    event_types = log |> Log.query("SELECT ocel_type FROM event_map_type") |> List.flatten()
    assert "transition" in event_types and "run_finished" in event_types
  end

  test "rejects attributes that are not in the schema" do
    assert_raise ArgumentError, ~r/unknown attributes/, fn ->
      Event.new("state_entered", :x, %{"bogus" => 1})
    end
  end

  test "sequence numbers continue after a restart of the log" do
    dir = Path.join(System.tmp_dir!(), "xeito-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "log.sqlite")

    first = start_supervised!({Log, path: path}, id: :first)
    Log.append(first, "r1", [Event.new("state_entered", :a, %{"state" => :a})])
    stop_supervised!(:first)

    second = start_supervised!({Log, path: path}, id: :second)

    assert {:ok, [2]} =
             Log.append(second, "r1", [Event.new("state_entered", :b, %{"state" => :b})])
  end
end
