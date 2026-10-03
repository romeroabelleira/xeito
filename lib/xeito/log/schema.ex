defmodule Xeito.Log.Schema do
  @moduledoc """
  OCEL 2.0 relational layout (SQLite) for Xeito's event types, plus one Xeito-specific table.

  OCEL 2.0 tables: `event`, `event_map_type`, `event_<type>`, `object`, `object_map_type`,
  `object_<type>`, `event_object`, `object_object`. Process-mining tools (e.g. PM4Py) read
  these directly and ignore any other tables.

  `xeito_term` stores the exact Erlang term of every event (`:erlang.term_to_binary/1`),
  indexed by `(run_id, seq)`. Replay and recovery read it, because JSON attributes cannot
  round-trip tuples and atoms.
  """

  @event_types %{
    "run_started" => ~w(machine machine_version input),
    "run_recovered" => ~w(state events_replayed),
    "event_received" => ~w(name data actor),
    "transition" => ~w(from_state to_state event_name actor implicit),
    "state_exited" => ~w(state),
    "state_entered" => ~w(state),
    "effect_requested" => ~w(effect_id kind args),
    "effect_completed" => ~w(effect_id kind result),
    "decision_made" =>
      ~w(effect_id decision_type value confidence actor model latency_ms input_hash tokens_in tokens_out usd joules_est),
    "run_finished" => ~w(status final_state),
    # `/undo` and `/redo` (`Xeito.Undo`), in the session's own stream (`within` the session):
    # a label against the effect whose change was reverted or put back.
    "step_undone" => ~w(effect_id label),
    "step_redone" => ~w(effect_id label),
    # Lines typed while a turn ran: queued, then sent or dropped (`Xeito.Session`).
    "prompt_queued" => ~w(text),
    "prompt_entered" => ~w(text),
    "prompt_dequeued" => ~w(text outcome)
  }

  @object_types %{
    "run" => ~w(machine machine_version status),
    "machine" => ~w(name version),
    "effect" => ~w(kind),
    "session" => ~w(cwd status)
  }

  @doc "Event types and their attribute columns."
  @spec event_types() :: %{String.t() => [String.t()]}
  def event_types, do: @event_types

  @doc "Object types and their attribute columns."
  @spec object_types() :: %{String.t() => [String.t()]}
  def object_types, do: @object_types

  @doc "DDL statements, idempotent."
  @spec statements() :: [String.t()]
  def statements do
    base = [
      "CREATE TABLE IF NOT EXISTS event (ocel_id TEXT PRIMARY KEY, ocel_type TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS event_map_type (ocel_type TEXT PRIMARY KEY, ocel_type_map TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS object (ocel_id TEXT PRIMARY KEY, ocel_type TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS object_map_type (ocel_type TEXT PRIMARY KEY, ocel_type_map TEXT NOT NULL)",
      "CREATE TABLE IF NOT EXISTS event_object (ocel_event_id TEXT NOT NULL, ocel_object_id TEXT NOT NULL, " <>
        "ocel_qualifier TEXT, PRIMARY KEY (ocel_event_id, ocel_object_id, ocel_qualifier))",
      "CREATE TABLE IF NOT EXISTS object_object (ocel_source_id TEXT NOT NULL, ocel_target_id TEXT NOT NULL, " <>
        "ocel_qualifier TEXT, PRIMARY KEY (ocel_source_id, ocel_target_id, ocel_qualifier))",
      "CREATE TABLE IF NOT EXISTS xeito_term (ocel_id TEXT PRIMARY KEY, run_id TEXT NOT NULL, " <>
        "seq INTEGER NOT NULL, type TEXT NOT NULL, term BLOB NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS xeito_term_run_seq ON xeito_term (run_id, seq)"
    ]

    events =
      Enum.flat_map(@event_types, fn {type, attrs} ->
        [
          "CREATE TABLE IF NOT EXISTS event_#{type} (ocel_id TEXT PRIMARY KEY, ocel_time TIMESTAMP NOT NULL" <>
            Enum.map_join(attrs, "", &", #{&1} TEXT") <> ")",
          "INSERT OR IGNORE INTO event_map_type (ocel_type, ocel_type_map) VALUES ('#{type}', '#{type}')"
        ]
      end)

    objects =
      Enum.flat_map(@object_types, fn {type, attrs} ->
        [
          "CREATE TABLE IF NOT EXISTS object_#{type} (ocel_id TEXT NOT NULL, ocel_time TIMESTAMP NOT NULL, " <>
            "ocel_changed_field TEXT" <> Enum.map_join(attrs, "", &", #{&1} TEXT") <> ")",
          "INSERT OR IGNORE INTO object_map_type (ocel_type, ocel_type_map) VALUES ('#{type}', '#{type}')"
        ]
      end)

    base ++ events ++ objects
  end
end
