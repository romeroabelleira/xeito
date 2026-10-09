defmodule Xeito.Telemetry do
  @moduledoc """
  `:telemetry` events for runs: a projection of what a run appends to the log, emitted right
  after the log write, never a separate truth ([06](docs/architecture/06-observability.md)).
  Handlers run in the run's process; one that raises is detached by `:telemetry`.

    * `[:xeito, :run, :start]`: metadata `run_id`, `machine`, `machine_version`
    * `[:xeito, :run, :transition]`: `run_id`, `from_state`, `to_state`, `event_name`, `actor`,
      `implicit`
    * `[:xeito, :effect, :stop]`: `run_id`, `effect_id`, `kind`
    * `[:xeito, :decision, :stop]`: `run_id`, `effect_id`, `decision_type`, `value`, `actor`,
      `model`; measurements `confidence`, `latency_ms`, `tokens_in`, `tokens_out`, `usd` and
      `joules_est`, those the decision has
    * `[:xeito, :run, :stop]`: `run_id`, `status`, `final_state`

  A run's input and an effect's result are left out: they can hold file contents and secrets,
  and a handler may send what it gets off the machine.
  """

  alias Xeito.Log.Event

  # Per projected event type: its telemetry name, the attributes copied into the metadata and
  # those that are measurements.
  @projected %{
    "run_started" => {[:xeito, :run, :start], ~w(machine machine_version)a, []},
    "transition" => {[:xeito, :run, :transition], ~w(from_state to_state event_name actor implicit)a, []},
    "effect_completed" => {[:xeito, :effect, :stop], ~w(effect_id kind)a, []},
    "decision_made" =>
      {[:xeito, :decision, :stop], ~w(effect_id decision_type value actor model)a,
       ~w(confidence latency_ms tokens_in tokens_out usd joules_est)a},
    "run_finished" => {[:xeito, :run, :stop], ~w(status final_state)a, []}
  }

  @doc "The names of the events emitted, for `:telemetry.attach_many/4`."
  @spec events() :: [[atom()]]
  def events, do: for({name, _, _} <- Map.values(@projected), do: name)

  @doc "Emits the telemetry events for a run's logged events, in order."
  @spec emit(String.t(), [Event.t()]) :: :ok
  def emit(run_id, events) do
    for event <- events,
        {name, measurements, metadata} <- List.wrap(project(run_id, event)),
        do: :telemetry.execute(name, measurements, metadata)

    :ok
  end

  @doc "The telemetry event for a logged event, or nil when the event type is not projected."
  @spec project(String.t(), Event.t()) :: {[atom()], map(), map()} | nil
  def project(run_id, %Event{type: type, attrs: attrs}) do
    case Map.fetch(@projected, type) do
      {:ok, {name, metadata, measurements}} ->
        {name, numbers(attrs, measurements), attrs |> take(metadata) |> Map.put(:run_id, run_id)}

      :error ->
        nil
    end
  end

  defp take(attrs, keys), do: for(key <- keys, Map.has_key?(attrs, "#{key}"), into: %{}, do: {key, attrs["#{key}"]})

  defp numbers(attrs, keys), do: for({key, value} <- take(attrs, keys), is_number(value), into: %{}, do: {key, value})
end
