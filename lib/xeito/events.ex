defmodule Xeito.Events do
  @moduledoc """
  Live event feed for clients (TUI, CLI, bridge): everything a run appends to the log, plus
  ephemeral streams that are not logged: model tokens and the output of running commands.

  Subscribers receive `{:xeito, run_id, event}` messages, where `event` is one of:

    * `%{type: "state_entered", attrs: %{...}}` and every other logged event type, with the
      attributes that went into the log
    * `%{type: "delta", attrs: %{"effect_id" => id, "text" => text}}` for streamed model output
    * `%{type: "output", attrs: %{"effect_id" => id, "text" => text}}` for a running command's
      output, as it arrives; the logged result holds it whole when the command ends

  Topics are run ids, or `:all`. Child runs (escalations, sub-machines) have ids that extend
  their parent's (`<parent>/e3/esc`), so a client following a session subscribes to `:all` and
  filters with `related?/2`.

  The feed is best effort and in-process: the log stays the source of truth, and a client that
  reconnects reads the log first.
  """

  alias Xeito.Log.Event

  @registry Xeito.EventRegistry

  @doc false
  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: @registry)

  @doc "Subscribes the calling process to a run id or to `:all`."
  @spec subscribe(String.t() | :all) :: :ok
  def subscribe(topic) do
    {:ok, _} = Registry.register(@registry, topic, [])
    :ok
  end

  @doc "Unsubscribes the calling process from a topic."
  @spec unsubscribe(String.t() | :all) :: :ok
  def unsubscribe(topic), do: Registry.unregister(@registry, topic)

  @doc "Publishes logged events of a run."
  @spec publish(String.t(), [Event.t()]) :: :ok
  def publish(run_id, events) do
    Enum.each(events, &broadcast(run_id, %{type: &1.type, attrs: &1.attrs}))
  end

  @doc "Publishes a streamed chunk of model output (not logged)."
  @spec delta(String.t() | nil, String.t(), String.t()) :: :ok
  def delta(nil, _effect_id, _text), do: :ok

  def delta(run_id, effect_id, text),
    do: broadcast(run_id, %{type: "delta", attrs: %{"effect_id" => effect_id, "text" => text}})

  @doc "Publishes a piece of a running command's output (not logged)."
  @spec output(String.t() | nil, String.t(), String.t()) :: :ok
  def output(nil, _effect_id, _text), do: :ok

  def output(run_id, effect_id, text),
    do: broadcast(run_id, %{type: "output", attrs: %{"effect_id" => effect_id, "text" => text}})

  @doc "Publishes a run notice that is not logged (for example `paused` in step mode)."
  @spec transient(String.t(), String.t(), map()) :: :ok
  def transient(run_id, type, attrs), do: broadcast(run_id, %{type: type, attrs: attrs})

  @doc "Sends `event` to the subscribers of `topic` as `{:xeito, topic, event}` (not logged)."
  @spec notify(String.t(), map()) :: :ok
  def notify(topic, event), do: dispatch(topic, {:xeito, topic, event})

  @doc "Whether `run_id` is `root` or one of its descendants."
  @spec related?(String.t(), String.t()) :: boolean()
  def related?(run_id, root), do: run_id == root or String.starts_with?(run_id, root <> "/")

  defp broadcast(run_id, event) do
    dispatch(run_id, {:xeito, run_id, event})
    dispatch(:all, {:xeito, run_id, event})
  end

  defp dispatch(topic, message) do
    if Process.whereis(@registry),
      do: Registry.dispatch(@registry, topic, &Enum.each(&1, fn {pid, _} -> send(pid, message) end))

    :ok
  end
end
