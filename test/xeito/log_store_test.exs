defmodule Xeito.LogStoreTest do
  use Xeito.Case, async: true

  alias Xeito.{Effect, Log, Machine}
  alias Xeito.Log.{Event, Store}
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
        {1, "run_started", {:run_started, Chat, "0.1.0", input}},
        {2, "effect_requested", {:effect_requested, logged}}
      ]
    end

    assert {:ok, %{desync: nil, pending: [^effect]}} = Recovery.rebuild(Chat, entries.(effect))

    tampered = put_in(effect.args.messages, [msg("system", "s"), msg("user", "something else")])
    assert {:ok, %{desync: "r/e1"}} = Recovery.rebuild(Chat, entries.(tampered))
  end
end
