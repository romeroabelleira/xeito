defmodule Xeito.LogStoreTest do
  use Xeito.Case, async: true

  alias Xeito.{Effect, Log, Machine}
  alias Xeito.Log.{Event, Sql, Store}
  alias Xeito.Machines.Chat
  alias Xeito.Run.Recovery

  defp msg(role, content), do: %{role: role, content: content}

  defp chat_requested(id, messages) do
    effect = %{Effect.chat(messages, tools: ["read"]) | id: id}

    Event.new(
      "effect_requested",
      {:effect_requested, effect},
      %{"effect_id" => id, "kind" => :chat, "args" => effect.args},
      [{id, "effect", "of"}]
    )
  end

  defp count(log, sql), do: log |> Log.query(sql) |> then(fn [[n]] -> n end)

  test "message lists are stored once per message, shared prefixes included, and read back exactly" do
    log = start_log!()
    system = msg("system", "be brief")
    turn1 = [system, msg("user", "hi")]
    turn2 = turn1 ++ [msg("assistant", "hello"), msg("user", "list files")]
    turn3 = turn2 ++ [msg("assistant", "ls"), msg("tool", "a.txt")]

    events = [
      Event.new("run_started", {:run_started, Chat, "0.1.0", %{messages: tl(turn1)}}, %{
        "input" => %{messages: tl(turn1)}
      }),
      chat_requested("r/e1", turn1),
      chat_requested("r/e2", turn2),
      chat_requested("r/e3", turn3)
    ]

    Log.append(log, "r", events)

    assert Log.read_run(log, "r") ==
             Enum.with_index(events, 1) |> Enum.map(fn {e, i} -> {i, e.type, e.term} end)

    # Six distinct messages in the chains starting at the system prompt, plus the input history
    # (a chain of its own, starting at "hi").
    assert count(log, "SELECT COUNT(*) FROM xeito_message") == 7

    # The OCEL attributes show the chain, not the text.
    [[args]] = Log.query(log, "SELECT args FROM event_effect_requested WHERE effect_id = 'r/e3'")
    assert %{"messages" => %{"chain" => head, "messages" => 6}} = JSON.decode!(args)
    assert head == Store.chain_id(turn3)
    refute args =~ "list files"
  end

  test "the event an effect result produces refers to the stored result" do
    log = start_log!()
    result = %{content: String.duplicate("a long answer ", 50), tool_calls: []}

    events = [
      Event.new("effect_completed", {:effect_completed, "r/e1", result}, %{
        "effect_id" => "r/e1",
        "result" => result
      }),
      Event.new("event_received", {:event, :chatted, result, :large}, %{
        "name" => :chatted,
        "data" => result
      })
    ]

    Log.append(log, "r", events)

    assert [{1, _, {:effect_completed, _, ^result}}, {2, _, {:event, :chatted, ^result, :large}}] =
             Log.read_run(log, "r")

    assert [[~s({"same_as":"r:1"})]] = Log.query(log, "SELECT data FROM event_event_received")
    [[bytes]] = Log.query(log, "SELECT length(term) FROM xeito_term WHERE seq = 2")
    assert bytes < 100
  end

  test "terms stored before the compact layout read as they are" do
    log = start_log!()
    Log.append(log, "r", [Event.new("state_entered", {:state_entered, :a}, %{"state" => :a})])

    old = {:effect_requested, %{Effect.chat([msg("user", "hi")]) | id: "r/e1"}}

    Log.query(
      log,
      "INSERT INTO xeito_term (ocel_id, run_id, seq, type, term) VALUES ('r:2', 'r', 2, 'effect_requested', ?1)",
      [{:blob, :erlang.term_to_binary(old)}]
    )

    assert [_, {2, "effect_requested", ^old}] = Log.read_run(log, "r")
  end

  test "sweep deletes only messages no event refers to" do
    log = start_log!()
    a = [msg("system", "s"), msg("user", "one")]
    b = a ++ [msg("assistant", "two")]
    Log.append(log, "r1", [chat_requested("r1/e1", a)])
    Log.append(log, "r2", [chat_requested("r2/e1", b)])

    Log.query(log, "DELETE FROM xeito_term_chain WHERE ocel_id = 'r2:1'")
    assert count(log, "SELECT COUNT(*) FROM xeito_message") == 3

    # Sweep runs on its own connection, as `mix xeito.log prune` does.
    [[path]] = Log.query(log, "SELECT file FROM pragma_database_list WHERE name = 'main'")
    {:ok, db} = Exqlite.Sqlite3.open(path)
    assert Store.sweep(db) == 1
    Exqlite.Sqlite3.close(db)

    assert Log.read_run(log, "r1") == [{1, "effect_requested", chat_requested("r1/e1", a).term}]
  end

  test "replay detects a logged effect that differs from the one it recomputes (desync)" do
    input = %{cwd: "/w", prompt: "hi", messages: [], system: "s"}
    [effect] = Machine.Engine.start(Machine.fetch!(Chat), input).effects
    effect = %{effect | id: "r/e1"}

    entries = fn logged ->
      [
        {1, "run_started", {:run_started, Chat, Machine.fetch!(Chat).version, input}},
        {2, "effect_requested", {:effect_requested, logged}}
      ]
    end

    assert {:ok, %{desync: nil, pending: [^effect]}} = Recovery.rebuild(Chat, entries.(effect))

    tampered = put_in(effect.args.messages, [msg("system", "s"), msg("user", "something else")])
    assert {:ok, %{desync: "r/e1"}} = Recovery.rebuild(Chat, entries.(tampered))
  end

  test "messages are stored as JSON that SQL can read; the term only when JSON is not exact" do
    log = start_log!()

    call = %{function: %{name: "bash", arguments: %{"command" => "ls"}}}

    chain = [
      msg("system", "s"),
      %{role: "assistant", content: "", tool_calls: [call]},
      %{role: "tool", tool_name: "bash", content: "a.txt"},
      # Not representable in JSON exactly: kept as an Erlang term as well.
      %{role: "user", content: "x", meta: {:tuple, 1}}
    ]

    Log.append(log, "r", [chat_requested("r/e1", chain)])
    assert [{1, _, {:effect_requested, effect}}] = Log.read_run(log, "r")
    assert effect.args.messages == chain

    assert Log.query(
             log,
             "SELECT json_extract(json, '$.role'), json_extract(json, '$.tool_calls[0].function.arguments.command'), " <>
               "term IS NULL FROM xeito_message ORDER BY depth"
           ) == [["system", nil, 1], ["assistant", "ls", 1], ["tool", nil, 1], ["user", nil, 0]]
  end

  test "a message table from before JSON storage is migrated on open" do
    dir = Path.join(System.tmp_dir!(), "xeito-mig-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "log.sqlite")
    chain = [msg("system", "s"), msg("user", "hi")]

    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "CREATE TABLE xeito_message (id TEXT PRIMARY KEY, parent TEXT, depth INTEGER NOT NULL, term BLOB NOT NULL)"
      )

    Enum.each(Enum.with_index(chain, 1), fn {m, depth} ->
      id = Store.chain_id(Enum.take(chain, depth))
      parent = if depth > 1, do: Store.chain_id(Enum.take(chain, depth - 1))

      Sql.exec(db, "INSERT INTO xeito_message VALUES (?1, ?2, ?3, ?4)", [
        id,
        parent,
        depth,
        {:blob, Store.pack(m)}
      ])
    end)

    Exqlite.Sqlite3.close(db)

    log = start_supervised!({Log, path: path}, id: make_ref())
    head = Store.chain_id(chain)

    assert Log.query(
             log,
             "SELECT json_extract(json, '$.content') FROM xeito_message ORDER BY depth"
           ) ==
             [["s"], ["hi"]]

    {:ok, db} = Exqlite.Sqlite3.open(path)
    assert Store.read_chain(db, head) == chain
    Exqlite.Sqlite3.close(db)
  end
end
