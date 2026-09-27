defmodule Xeito.Run do
  @moduledoc """
  One supervised `gen_statem` process per run, interpreting a `Xeito.Machine`.

  The gen_statem state is the active *leaf* of the statechart, and the data holds the run's
  context. For every event the run:

    1. asks `Xeito.Machine.Engine` for the step (pure),
    2. appends the events to `Xeito.Log` (synchronously, before acknowledging anything),
    3. moves to the new leaf, re-arms the state timeout and dispatches entry effects.

  Effect results come back as messages. They are logged together with the event they produce.

  If the process crashes, its supervisor restarts it with the same `run_id`, and `init/1`
  rebuilds the state from the log via `Xeito.Run.Recovery`. Pending effects are re-dispatched.
  A run pins the machine version it started with; recovery refuses a changed version.

  See `docs/architecture/02-state-machine-core.md`.
  """

  @behaviour :gen_statem

  alias Xeito.{Effect, Effects, Log, Machine}
  alias Xeito.Log.Event
  alias Xeito.Machine.Engine
  alias Xeito.Run.Recovery

  @type run_id :: String.t()

  # --- Client API --------------------------------------------------------------------------

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :run_id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Starts a run process. Options: `:run_id`, `:machine` (module), `:input` (map), `:log`,
  `:runner` (see `Xeito.Effects`).
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    :gen_statem.start_link(via(Keyword.fetch!(opts, :run_id)), __MODULE__, opts, [])
  end

  @doc "Sends an external event. Returns `{:ok, leaf}` if it caused a transition, else `:ignored`."
  @spec send_event(run_id(), term(), term(), atom()) :: {:ok, atom()} | :ignored
  def send_event(run_id, name, data \\ %{}, actor \\ :human) do
    :gen_statem.call(via(run_id), {:event, name, data, actor})
  end

  @doc "Returns `%{leaf: atom, ctx: map}` of a live run."
  @spec snapshot(run_id()) :: %{leaf: atom(), ctx: map()}
  def snapshot(run_id), do: :gen_statem.call(via(run_id), :snapshot)

  @doc "The pid of a live run, or `nil`."
  @spec whereis(run_id()) :: pid() | nil
  def whereis(run_id) do
    case Registry.lookup(Xeito.RunRegistry, run_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "The logged outcome of a finished run: `{:ok, %{status, state, ctx}}`, or `:running`."
  @spec result(Log.server(), run_id()) :: {:ok, map()} | :running
  def result(log, run_id) do
    log
    |> Log.read_run(run_id)
    |> Enum.find_value(:running, fn
      {_, "run_finished", {:run_finished, status, state, ctx}} ->
        {:ok, %{status: status, state: state, ctx: ctx}}

      _ ->
        nil
    end)
  end

  defp via(run_id), do: {:via, Registry, {Xeito.RunRegistry, run_id}}

  # --- gen_statem --------------------------------------------------------------------------

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    module = Keyword.fetch!(opts, :machine)

    data = %{
      run_id: run_id,
      machine: Machine.fetch!(module),
      log: Keyword.get(opts, :log, Xeito.Log),
      runner: Keyword.get(opts, :runner, :none),
      ctx: %{},
      effect_count: 0,
      effects: %{}
    }

    case Log.read_run(data.log, run_id) do
      [] -> fresh(data, Keyword.get(opts, :input, %{}))
      entries -> recover(data, entries)
    end
  end

  defp fresh(data, input) do
    %{machine: machine, run_id: run_id, log: log} = data

    Log.put_object(log, "machine:#{machine.name}@#{machine.version}", "machine", %{
      name: machine.name,
      version: machine.version
    })

    Log.put_object(log, run_id, "run", %{
      machine: machine.name,
      machine_version: machine.version,
      status: "running"
    })

    Log.relate(log, run_id, "machine:#{machine.name}@#{machine.version}", "instance_of")

    started = Engine.start(machine, input)
    {effects, data} = number_effects(started.effects, %{data | ctx: started.ctx})

    run_started =
      Event.new("run_started", {:run_started, machine.module, machine.version, input}, %{
        "machine" => machine.name,
        "machine_version" => machine.version,
        "input" => input
      })

    log!(
      data,
      [run_started | Enum.map(started.entered, &entered_event/1)] ++
        Enum.map(effects, &requested_event/1)
    )

    enter(started.leaf, data, effects, :init)
  end

  defp recover(data, entries) do
    case Recovery.rebuild(data.machine.module, entries) do
      {:ok, %{finished: true}} ->
        :ignore

      {:ok, rebuilt} ->
        data = %{data | ctx: rebuilt.ctx, effect_count: rebuilt.effect_count}

        event =
          Event.new("run_recovered", {:run_recovered, rebuilt.leaf}, %{
            "state" => rebuilt.leaf,
            "events_replayed" => rebuilt.replayed
          })

        log!(data, [event])
        enter(rebuilt.leaf, data, rebuilt.pending, :init)

      {:error, reason} ->
        {:stop, {:recovery_failed, reason}}
    end
  end

  @impl :gen_statem
  def handle_event({:call, from}, {:event, name, event_data, actor}, leaf, data) do
    process(leaf, data, name, event_data, actor, [], from)
  end

  def handle_event({:call, from}, :snapshot, leaf, data) do
    {:keep_state_and_data, [{:reply, from, %{leaf: leaf, ctx: data.ctx}}]}
  end

  def handle_event(:info, {:xeito_effect, id, result}, leaf, data) do
    case Map.pop(data.effects, id) do
      {nil, _} ->
        :keep_state_and_data

      {effect, effects} ->
        completed =
          Event.new(
            "effect_completed",
            {:effect_completed, id, result},
            %{"effect_id" => id, "kind" => effect.kind, "result" => result},
            [
              {id, "effect", "of"}
            ]
          )

        {name, event_data} = Effect.to_event(effect, result)
        process(leaf, %{data | effects: effects}, name, event_data, :code, [completed], nil)
    end
  end

  def handle_event(:state_timeout, name, leaf, data) do
    process(leaf, data, name, %{}, :code, [], nil)
  end

  defp process(leaf, data, name, event_data, actor, prefix, from) do
    received =
      Event.new("event_received", {:event, name, event_data, actor}, %{
        "name" => name,
        "data" => event_data,
        "actor" => actor
      })

    case Engine.handle(data.machine, leaf, data.ctx, name, event_data) do
      :ignored ->
        log!(data, prefix ++ [received])
        {:keep_state, data, reply(from, :ignored)}

      {:ok, step} ->
        {effects, data} = number_effects(step.effects, %{data | ctx: step.ctx, effects: %{}})

        transition =
          Event.new("transition", {:transition, step.from, step.to, name, actor}, %{
            "from_state" => step.from,
            "to_state" => step.to,
            "event_name" => name,
            "actor" => if(step.implicit, do: :code, else: actor),
            "implicit" => step.implicit
          })

        log!(
          data,
          prefix ++
            [received, transition] ++
            Enum.map(step.exited, &exited_event/1) ++
            Enum.map(step.entered, &entered_event/1) ++ Enum.map(effects, &requested_event/1)
        )

        enter(step.to, data, effects, from)
    end
  end

  # Moves to `leaf`: finishes the run on a final state, otherwise arms the timeout and dispatches.
  defp enter(leaf, data, effects, from) do
    machine = data.machine

    if Machine.final?(machine, leaf) do
      finish(leaf, data, from)
    else
      Enum.each(effects, &Effects.dispatch(data.runner, &1, self()))
      data = %{data | effects: Map.merge(data.effects, Map.new(effects, &{&1.id, &1}))}
      {ms, timeout_event} = Machine.timeout(machine, leaf)
      actions = [{:state_timeout, ms, timeout_event} | reply(from, {:ok, leaf})]

      if from == :init,
        do: {:ok, leaf, data, [{:state_timeout, ms, timeout_event}]},
        else: {:next_state, leaf, data, actions}
    end
  end

  defp finish(leaf, data, from) do
    status = if leaf == :failed, do: :failed, else: :done

    log!(data, [
      Event.new("run_finished", {:run_finished, status, leaf, data.ctx}, %{
        "status" => status,
        "final_state" => leaf
      })
    ])

    Log.put_object(data.log, data.run_id, "run", %{status: status}, "status")

    case from do
      :init -> :ignore
      nil -> {:stop, :normal, data}
      from -> {:stop_and_reply, :normal, [{:reply, from, {:ok, leaf}}], data}
    end
  end

  defp reply(nil, _msg), do: []
  defp reply(:init, _msg), do: []
  defp reply(from, msg), do: [{:reply, from, msg}]

  defp number_effects(effects, data) do
    numbered =
      effects
      |> Enum.with_index(data.effect_count + 1)
      |> Enum.map(fn {effect, n} -> %{effect | id: "#{data.run_id}/e#{n}"} end)

    {numbered, %{data | effect_count: data.effect_count + length(effects)}}
  end

  defp entered_event(state),
    do: Event.new("state_entered", {:state_entered, state}, %{"state" => state})

  defp exited_event(state),
    do: Event.new("state_exited", {:state_exited, state}, %{"state" => state})

  defp requested_event(effect) do
    Event.new(
      "effect_requested",
      {:effect_requested, effect},
      %{"effect_id" => effect.id, "kind" => effect.kind, "args" => effect.args},
      [
        {effect.id, "effect", "of"}
      ]
    )
  end

  defp log!(data, events) do
    {:ok, _seqs} = Log.append(data.log, data.run_id, events)
    :ok
  end
end
