defmodule Xeito.Log.Store do
  @moduledoc """
  How events are stored compactly, and read back exactly (`Xeito.Log` uses it; nothing else
  needs to know). The log records *inputs* once and refers to them afterwards, the way rollback
  netcode exchanges inputs rather than game state
  (`docs/architecture/05-event-log-and-process-mining.md#storage`):

    * **Message chains.** Any list of chat messages inside an event (a chat effect's messages, a
      run's input history, a chat run's final turn) is stored once per message in
      `xeito_message`, each row pointing to its parent. A message's id hashes its parent's id and
      its own content, so the id of a chain's last message is a checksum of the whole
      conversation up to it, and shared prefixes (system prompt, earlier turns, other sessions)
      are stored once. Messages are stored as JSON (`json`), so any SQLite tool can read a
      conversation; a message JSON cannot reproduce exactly also keeps its Erlang term (`term`,
      otherwise `NULL`). In the event it becomes `{:xeito_chain, head_id, count}`; in the OCEL
      attributes `%{"chain" => head_id, "messages" => count}`. `xeito_term_chain` records which
      event refers to which chain, so pruning can sweep unreferenced messages.
    * **Results once.** The event an effect's result produces carries the same payload as the
      `effect_completed` logged just before it; it is stored as a reference to that event.
    * **Compressed terms.** Terms are stored with `term_to_binary(t, [:compressed, :deterministic])`
      (small terms stay uncompressed).

  Reading reverses all three, so `Xeito.Log.read_run/2` returns the terms that were appended.
  Logs written before this layout have plain terms and read as they are.
  """

  alias Xeito.Log.{Codec, Event, Sql}

  @type db :: Exqlite.Sqlite3.db()

  @doc """
  Creates the store's tables (idempotent) and migrates a message table from before messages were
  stored as JSON. Call it once per connection before using the store.
  """
  @spec prepare(db()) :: :ok
  def prepare(db) do
    Enum.each(statements(), &Sql.exec(db, &1))
    if not column?(db, "xeito_message", "json"), do: migrate_messages(db)
    :ok
  end

  defp statements do
    [
      "CREATE TABLE IF NOT EXISTS xeito_message (id TEXT PRIMARY KEY, parent TEXT, " <>
        "depth INTEGER NOT NULL, json TEXT NOT NULL, term BLOB)",
      "CREATE TABLE IF NOT EXISTS xeito_term_chain (ocel_id TEXT NOT NULL, head TEXT NOT NULL, " <>
        "PRIMARY KEY (ocel_id, head))"
    ]
  end

  defp column?(db, table, column),
    do:
      Sql.select(db, "SELECT 1 FROM pragma_table_info(?1) WHERE name = ?2", [table, column]) != []

  # The first layout kept only the Erlang term. Ids do not change (they hash the term).
  defp migrate_messages(db) do
    Sql.transaction(db, fn ->
      Sql.exec(db, "ALTER TABLE xeito_message RENAME TO xeito_message_etf")
      Enum.each(statements(), &Sql.exec(db, &1))

      for [id, parent, depth, blob] <-
            Sql.select(db, "SELECT id, parent, depth, term FROM xeito_message_etf") do
        insert_message(db, id, parent, depth, :erlang.binary_to_term(blob))
      end

      Sql.exec(db, "DROP TABLE xeito_message_etf")
    end)
  end

  defp insert_message(db, id, parent, depth, message) do
    {json, term} = message_row(message)

    Sql.exec(
      db,
      "INSERT OR IGNORE INTO xeito_message (id, parent, depth, json, term) VALUES (?1, ?2, ?3, ?4, ?5)",
      [id, parent, depth, json, term]
    )
  end

  @doc """
  How a message is stored: `{json, term}`, where `term` is `nil` when the JSON reads back to
  exactly the same message (`from_json/1`), and the packed term otherwise.
  """
  @spec message_row(map()) :: {String.t(), {:blob, binary()} | nil}
  def message_row(message) do
    json = Codec.encode(message)
    exact? = from_json(JSON.decode!(json)) == message
    {json, if(exact?, do: nil, else: {:blob, pack(message)})}
  end

  # Chat messages have atom keys (`role`, `content`, `tool_calls`, `tool_name`, and `function`,
  # `name`, `arguments` inside a call); a call's arguments keep the model's string keys.
  @message_keys %{
    "role" => :role,
    "content" => :content,
    "tool_calls" => :tool_calls,
    "tool_name" => :tool_name
  }
  @call_keys %{"function" => :function}
  @function_keys %{"name" => :name, "arguments" => :arguments}

  @doc "Reads a stored message JSON (decoded) back into a chat message."
  @spec from_json(map()) :: map()
  def from_json(%{} = message) do
    message
    |> atomize(@message_keys)
    |> Map.replace_lazy(:tool_calls, fn
      calls when is_list(calls) -> Enum.map(calls, &call_from_json/1)
      other -> other
    end)
  end

  defp call_from_json(%{} = call),
    do:
      call
      |> atomize(@call_keys)
      |> Map.replace_lazy(:function, fn
        %{} = f -> atomize(f, @function_keys)
        other -> other
      end)

  defp call_from_json(other), do: other

  defp atomize(map, keys), do: Map.new(map, fn {k, v} -> {Map.get(keys, k, k), v} end)

  # --- writing -------------------------------------------------------------------------------

  @doc """
  Prepares a batch of events of one run for storage, writing the message chains they refer to.
  Takes `[{seq, event}]` and returns `[{seq, event_with_stored_attrs, term_blob, chain_heads}]`.
  Call it inside the transaction that inserts the events.
  """
  @spec encode(db(), String.t(), [{pos_integer(), Event.t()}]) ::
          [{pos_integer(), Event.t(), binary(), [String.t()]}]
  def encode(db, run_id, numbered) do
    {encoded, _last_result} =
      Enum.map_reduce(numbered, nil, fn {seq, event}, last_result ->
        {term, attrs} = dedupe(run_id, event, last_result)
        {term, heads} = chains_in_term(db, term)
        attrs = Map.new(attrs, fn {k, v} -> {k, chains_in_attr(v)} end)

        {{seq, %{event | attrs: attrs}, pack(term), Enum.uniq(heads)},
         completed_result(event, seq) || last_result}
      end)

    encoded
  end

  @doc "Records which chains an event refers to."
  @spec put_refs(db(), String.t(), [String.t()]) :: :ok
  def put_refs(db, ocel_id, heads) do
    Enum.each(
      heads,
      &Sql.exec(db, "INSERT OR IGNORE INTO xeito_term_chain (ocel_id, head) VALUES (?1, ?2)", [
        ocel_id,
        &1
      ])
    )
  end

  @doc "The stored form of a term."
  @spec pack(term()) :: binary()
  def pack(term), do: :erlang.term_to_binary(term, [:compressed, :deterministic])

  # An event carrying exactly the result of the `effect_completed` just before it (in the same
  # batch) refers to that event instead of repeating the payload.
  defp dedupe(run_id, %Event{type: "event_received", term: {:event, name, data, actor}} = e, last)
       when last != nil do
    case last do
      {^data, seq} ->
        {{:event, name, {:xeito_same_as, seq}, actor},
         Map.put(e.attrs, "data", %{"same_as" => "#{run_id}:#{seq}"})}

      _ ->
        {e.term, e.attrs}
    end
  end

  defp dedupe(_run_id, event, _last), do: {event.term, event.attrs}

  defp completed_result(%Event{type: "effect_completed", term: {:effect_completed, _, r}}, seq),
    do: {r, seq}

  defp completed_result(_event, _seq), do: nil

  defp chains_in_term(db, term) do
    walk(term, [], fn
      value, heads when is_list(value) ->
        if messages?(value) do
          head = put_chain(db, value)
          {:replace, {:xeito_chain, head, length(value)}, [head | heads]}
        else
          :descend
        end

      _value, _heads ->
        :descend
    end)
  end

  defp chains_in_attr(value) do
    {value, nil} =
      walk(value, nil, fn
        list, nil when is_list(list) ->
          if messages?(list),
            do: {:replace, %{"chain" => chain_id(list), "messages" => length(list)}, nil},
            else: :descend

        _value, nil ->
          :descend
      end)

    value
  end

  @doc "True for a non-empty list of chat messages (maps with a string `role`)."
  @spec messages?(term()) :: boolean()
  def messages?([_ | _] = list), do: Enum.all?(list, &message?/1)
  def messages?(_), do: false

  defp message?(%{role: role}) when is_binary(role), do: true
  defp message?(%{"role" => role}) when is_binary(role), do: true
  defp message?(_), do: false

  @doc "Writes a chain of messages (those not stored yet) and returns the id of its last one."
  @spec put_chain(db(), [map()]) :: String.t()
  def put_chain(db, messages) do
    nodes = nodes(messages)
    {head, _, _, _} = List.last(nodes)

    # Ids are content hashes of the whole prefix: if the head exists, so does every ancestor.
    if Sql.select(db, "SELECT 1 FROM xeito_message WHERE id = ?1", [head]) == [] do
      for {id, parent, depth, message} <- nodes,
          do: insert_message(db, id, parent, depth, message)
    end

    head
  end

  @doc "The id of a chain's last message, without storing anything."
  @spec chain_id([map()]) :: String.t()
  def chain_id(messages) do
    {head, _, _, _} = messages |> nodes() |> List.last()
    head
  end

  defp nodes(messages) do
    {nodes, _} =
      messages
      |> Enum.with_index(1)
      |> Enum.map_reduce(nil, fn {message, depth}, parent ->
        id = hash(parent, message)
        {{id, parent, depth, message}, id}
      end)

    nodes
  end

  defp hash(parent, message) do
    :crypto.hash(:sha256, [parent || "", :erlang.term_to_binary(message, [:deterministic])])
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  # --- reading -------------------------------------------------------------------------------

  @doc "Reads stored rows `[[seq, type, blob]]` of one run back into `[{seq, type, term}]`."
  @spec decode(db(), [[term()]]) :: [{pos_integer(), String.t(), term()}]
  def decode(db, rows) do
    {decoded, _} =
      Enum.map_reduce(rows, {%{}, %{}}, fn [seq, type, blob], {chains, by_seq} ->
        {term, chains} = expand(db, :erlang.binary_to_term(blob), chains)
        term = resolve_same_as(term, by_seq)
        {{seq, type, term}, {chains, Map.put(by_seq, seq, term)}}
      end)

    decoded
  end

  defp resolve_same_as({:event, name, {:xeito_same_as, seq}, actor}, by_seq) do
    {:effect_completed, _id, result} = Map.fetch!(by_seq, seq)
    {:event, name, result, actor}
  end

  defp resolve_same_as(term, _by_seq), do: term

  defp expand(db, term, chains) do
    walk(term, chains, fn
      {:xeito_chain, head, count}, chains when is_binary(head) and is_integer(count) ->
        {messages, chains} = chain(db, head, count, chains)
        {:replace, messages, chains}

      _value, _chains ->
        :descend
    end)
  end

  defp chain(_db, head, _count, chains) when is_map_key(chains, head),
    do: {Map.fetch!(chains, head), chains}

  defp chain(db, head, count, chains) do
    messages = read_chain(db, head)

    unless length(messages) == count,
      do: raise("message chain #{head} has #{length(messages)} messages, expected #{count}")

    {messages, Map.put(chains, head, messages)}
  end

  @doc "The messages of the chain ending at `head`, oldest first."
  @spec read_chain(db(), String.t()) :: [map()]
  def read_chain(db, head) do
    Sql.select(
      db,
      """
      WITH RECURSIVE c(id, parent, depth, json, term) AS (
        SELECT id, parent, depth, json, term FROM xeito_message WHERE id = ?1
        UNION ALL
        SELECT m.id, m.parent, m.depth, m.json, m.term FROM xeito_message m JOIN c ON m.id = c.parent)
      SELECT json, term FROM c ORDER BY depth
      """,
      [head]
    )
    |> Enum.map(fn
      [json, nil] -> json |> JSON.decode!() |> from_json()
      [_json, blob] -> :erlang.binary_to_term(blob)
    end)
  end

  # --- retention -----------------------------------------------------------------------------

  @doc "Deletes messages no stored event refers to (directly or as an ancestor). Returns the count."
  @spec sweep(db()) :: non_neg_integer()
  def sweep(db) do
    [[before]] = Sql.select(db, "SELECT COUNT(*) FROM xeito_message")

    Sql.exec(db, """
    WITH RECURSIVE live(id) AS (
      SELECT head FROM xeito_term_chain
      UNION
      SELECT m.parent FROM xeito_message m JOIN live ON m.id = live.id WHERE m.parent IS NOT NULL)
    DELETE FROM xeito_message WHERE id NOT IN (SELECT id FROM live)
    """)

    [[remaining]] = Sql.select(db, "SELECT COUNT(*) FROM xeito_message")
    before - remaining
  end

  # --- term walking --------------------------------------------------------------------------

  # Rebuilds a term, threading an accumulator. `fun` sees each sub-term first and returns
  # `{:replace, new, acc}` or `:descend`. Binaries, numbers and atoms are left as they are;
  # structs keep their type (their `__struct__` atom walks to itself).
  defp walk(term, acc, fun) do
    case fun.(term, acc) do
      {:replace, new, acc} -> {new, acc}
      :descend -> descend(term, acc, fun)
    end
  end

  defp descend(list, acc, fun) when is_list(list), do: walk_list(list, acc, fun)

  defp descend(tuple, acc, fun) when is_tuple(tuple) do
    {list, acc} = tuple |> Tuple.to_list() |> walk_list(acc, fun)
    {List.to_tuple(list), acc}
  end

  defp descend(map, acc, fun) when is_map(map) do
    map
    |> :maps.to_list()
    |> Enum.map_reduce(acc, fn {k, v}, acc ->
      {v, acc} = walk(v, acc, fun)
      {{k, v}, acc}
    end)
    |> then(fn {pairs, acc} -> {:maps.from_list(pairs), acc} end)
  end

  defp descend(other, acc, _fun), do: {other, acc}

  # Also handles improper lists.
  defp walk_list([], acc, _fun), do: {[], acc}

  defp walk_list([h | t], acc, fun) do
    {h, acc} = walk(h, acc, fun)
    {t, acc} = walk_list(t, acc, fun)
    {[h | t], acc}
  end

  defp walk_list(tail, acc, fun), do: walk(tail, acc, fun)
end
