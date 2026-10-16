defmodule Xeito.Session.Notify do
  @moduledoc """
  The session's outbound side: events on its topic and entries in its own log stream.

  Every function takes the session state (it reads `id` and `log`). `notice/2` and `error/2`
  return the state unchanged, so a command can end with either. Events go to
  `Xeito.Session.topic/1` as `%{type: type, run: run_id, attrs: map}`.
  """

  alias Xeito.Events
  alias Xeito.Log
  alias Xeito.Session

  @doc "Emits an event of `type` for `run` (nil for the session itself) to the session's subscribers."
  @spec emit(Session.state(), String.t(), String.t() | nil, map()) :: :ok
  def emit(s, type, run, attrs), do: Events.notify(Session.topic(s.id), %{type: type, run: run, attrs: attrs})

  @doc "Emits a `notice` event with `text`; returns the state."
  @spec notice(Session.state(), String.t()) :: Session.state()
  def notice(s, text) do
    emit(s, "notice", nil, %{"text" => text})
    s
  end

  @doc "Emits an `error` event with `text`; returns the state."
  @spec error(Session.state(), String.t()) :: Session.state()
  def error(s, text) do
    emit(s, "error", nil, %{"text" => text})
    s
  end

  @doc "Appends an event of `type` with `attrs` to the session's own stream in the log."
  @spec log_event(Session.state(), String.t(), map()) :: {:ok, [pos_integer()]}
  def log_event(s, type, attrs), do: Log.append(s.log, s.id, [Log.Event.new(type, {String.to_atom(type), attrs}, attrs)])
end
