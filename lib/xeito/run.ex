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

  alias Xeito.Budget
  alias Xeito.Decision
  alias Xeito.Decision.Type

  # --- Client API --------------------------------------------------------------------------

  alias Xeito.Effect
  alias Xeito.Effects
  alias Xeito.Log
  alias Xeito.Log.Event
  alias Xeito.Machine
  alias Xeito.Machine.Engine
  alias Xeito.Run.Recovery

  @type run_id :: String.t()

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

  @doc """
  Halts a run where it is, together with the runs under it (delegated `…/eN/run`, escalations
  `…/eN/esc`): effects in flight are killed, and each run finishes with status `:halted` in its
  current state. A halted run is finished: it is not recovered. Returns `:ok`, or
  `{:error, :not_running}`.
  """
  @spec halt(run_id(), atom()) :: :ok | {:error, :not_running}
  def halt(run_id, actor \\ :human) do
    # The run first, so it cannot react to a halted child's result.
    result = halt_one(run_id, actor)
    run_id |> runs_under() |> Enum.each(&halt_one(&1, actor))
    result
  end

  defp halt_one(run_id, actor) do
    {:ok, _leaf} = :gen_statem.call(via(run_id), {:halt, actor})
    :ok
  catch
    :exit, _ -> {:error, :not_running}
  end

  defp runs_under(run_id) do
    Xeito.RunRegistry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&String.starts_with?(&1, run_id <> "/"))
  end

  @doc """
  Sets the debug settings of a live run: `%{step: boolean, breakpoints: [breakpoint]}`.

  A breakpoint is `{:state, name}` (pause on any result arriving in that state),
  `{:decision, module}` (pause on that decision type's result) or `{:confidence_below, x}`
  (pause on a decision whose confidence is below `x`). With `step: true` the run pauses before
  every effect result. Turning step mode off releases a held result.
  See `docs/architecture/06-observability.md#2-step`.
  """
  @spec debug(run_id(), map()) :: :ok
  def debug(run_id, settings), do: :gen_statem.call(via(run_id), {:debug, settings})

  @doc """
  Releases the result a paused run is holding. With `{:decide, value}`, a held decision is
  replaced by a human decision of that value (logged with `actor: :human`, a labelled example).
  Returns `:ok`, `{:error, :not_paused}` or `{:error, :invalid_value}`.
  """
  @spec step(run_id(), :next | {:decide, atom()}) :: :ok | {:error, atom()}
  def step(run_id, how \\ :next), do: :gen_statem.call(via(run_id), {:step, how})

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

  @doc """
  Totals of the decisions a run made: count, latency, tokens, USD and estimated joules, summed
  from its `decision_made` events.
  """
  @spec cost(Log.server(), run_id()) :: map()
  def cost(log, run_id) do
    [[n, ms, tin, tout, usd, joules]] =
      Log.query(
        log,
        "SELECT COUNT(*), COALESCE(SUM(d.latency_ms), 0), COALESCE(SUM(d.tokens_in), 0), " <>
          "COALESCE(SUM(d.tokens_out), 0), COALESCE(SUM(d.usd), 0), COALESCE(SUM(d.joules_est), 0) " <>
          "FROM event_decision_made d JOIN event_object eo ON eo.ocel_event_id = d.ocel_id " <>
          "WHERE eo.ocel_object_id = ?1 AND eo.ocel_qualifier = 'within'",
        [run_id]
      )

    %{
      decisions: n,
      latency_ms: ms,
      tokens_in: tin,
      tokens_out: tout,
      usd: usd,
      joules_est: joules
    }
  end

  # --- gen_statem --------------------------------------------------------------------------

  @doc "Waits until run `id` has finished. Returns its logged result or `:timeout`."
  @spec await(Log.server(), String.t(), timeout()) :: {:ok, map()} | :timeout
  def await(log, id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait(log, id, deadline)
  end

  defp wait(log, id, deadline) do
    case result(log, id) do
      {:ok, result} ->
        {:ok, result}

      :running ->
        remaining = deadline - System.monotonic_time(:millisecond)

        cond do
          remaining <= 0 ->
            :timeout

          pid = whereis(id) ->
            ref = Process.monitor(pid)

            receive do
              {:DOWN, ^ref, :process, _, _} -> wait(log, id, deadline)
            after
              min(remaining, 1_000) ->
                Process.demonitor(ref, [:flush])
                wait(log, id, deadline)
            end

          true ->
            # Not running and not finished: being restarted by its supervisor.
            Process.sleep(20)
            wait(log, id, deadline)
        end
    end
  end

  defp via(run_id), do: {:via, Registry, {Xeito.RunRegistry, run_id}}

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    module = Keyword.fetch!(opts, :machine)

    data = %{
      run_id: run_id,
      machine: Machine.fetch!(module),
      log: Keyword.get(opts, :log, Log),
      runner: Keyword.get(opts, :runner, :none),
      ctx: %{},
      effect_count: 0,
      effects: %{},
      debug: Keyword.get(opts, :debug) || %{step: false, breakpoints: []},
      held: nil,
      queued: [],
      # The tasks of effects in flight, by effect id, so a halt can stop them.
      tasks: %{}
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

      {:ok, %{desync: id}} when id != nil ->
        {:stop, {:recovery_failed, {:desync, id}}}

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
  def handle_event({:call, from}, request, leaf, data), do: call(request, from, leaf, data)
  def handle_event(:info, {:xeito_effect, _id, _result} = msg, leaf, data), do: effect_result(msg, leaf, data)
  def handle_event(:state_timeout, name, leaf, data), do: timed_out(name, leaf, data)

  defp call({:event, name, event_data, actor}, from, leaf, data),
    do: process(leaf, data, name, event_data, actor, [], from)

  defp call({:halt, actor}, from, leaf, data) do
    Enum.each(data.tasks, fn {_id, pid} -> Process.exit(pid, :kill) end)

    halted =
      Event.new("event_received", {:event, :halt, %{}, actor}, %{"name" => :halt, "data" => %{}, "actor" => actor})

    finish(leaf, data, from, :halted, [halted])
  end

  defp call(:snapshot, from, leaf, data),
    do: {:keep_state_and_data, [{:reply, from, %{leaf: leaf, ctx: data.ctx, paused: data.held != nil}}]}

  defp call({:debug, settings}, from, leaf, data), do: set_debug(settings, from, leaf, data)
  defp call({:step, _how}, from, _leaf, %{held: nil}), do: {:keep_state_and_data, [{:reply, from, {:error, :not_paused}}]}
  defp call({:step, how}, from, leaf, data), do: release(leaf, data, from, how)

  defp set_debug(settings, from, leaf, data) do
    data = %{data | debug: Map.merge(%{step: false, breakpoints: []}, settings)}

    if data.held && not data.debug.step,
      do: release(leaf, data, from, :next),
      else: {:keep_state, data, [{:reply, from, :ok}]}
  end

  # While a result is held, further results wait in order; timeouts are dropped (a paused
  # run is under human control, and the next state re-arms its own timeout).
  defp effect_result({_, id, _} = msg, _leaf, %{held: held} = data) when held != nil,
    do: {:keep_state, %{data | queued: data.queued ++ [msg], tasks: Map.delete(data.tasks, id)}}

  defp effect_result({_, id, result} = msg, leaf, data) do
    data = %{data | tasks: Map.delete(data.tasks, id)}

    case Map.fetch(data.effects, id) do
      {:ok, effect} ->
        if pause?(data, leaf, effect, result),
          do: hold(leaf, data, msg, effect, result),
          else: complete(leaf, data, id, result)

      :error ->
        :keep_state_and_data
    end
  end

  defp timed_out(_name, _leaf, %{held: held}) when held != nil, do: :keep_state_and_data
  defp timed_out(name, leaf, data), do: process(leaf, data, name, %{}, :code, [], nil)

  defp complete(leaf, data, id, result) do
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
        prefix = [completed | decision_events(effect, result)]

        process(
          leaf,
          %{data | effects: effects},
          name,
          event_data,
          actor(effect, result),
          prefix,
          nil
        )
    end
  end

  # --- step mode and breakpoints -------------------------------------------------------------

  defp pause?(%{debug: %{step: true}}, _leaf, _effect, _result), do: true

  defp pause?(%{debug: %{breakpoints: breakpoints}}, leaf, effect, result),
    do: Enum.any?(breakpoints, &breakpoint?(&1, leaf, effect, result))

  defp breakpoint?({:state, state}, leaf, _effect, _result), do: state == leaf

  defp breakpoint?({:decision, type}, _leaf, %Effect{kind: :decide, args: args}, _result), do: args.decision == type

  defp breakpoint?({:confidence_below, x}, _leaf, %Effect{kind: :decide}, %{decision: d}),
    do: is_number(d[:confidence]) and d[:confidence] < x

  defp breakpoint?(_breakpoint, _leaf, _effect, _result), do: false

  defp hold(leaf, data, msg, effect, result) do
    Xeito.Events.transient(data.run_id, "paused", %{
      "state" => leaf,
      "kind" => effect.kind,
      "summary" => summary(effect, result)
    })

    {:keep_state, %{data | held: msg}}
  end

  defp release(leaf, data, from, how) do
    {:xeito_effect, id, result} = data.held
    effect = Map.fetch!(data.effects, id)

    case override(effect, result, how) do
      {:ok, result} ->
        Enum.each(data.queued, &send(self(), &1))
        data = %{data | held: nil, queued: []}

        case complete(leaf, data, id, result) do
          {:keep_state, data, actions} ->
            {:keep_state, data, [{:reply, from, :ok} | actions]}

          {:next_state, to, data, actions} ->
            {:next_state, to, data, [{:reply, from, :ok} | actions]}

          {:stop, reason, data} ->
            {:stop_and_reply, reason, [{:reply, from, :ok}], data}

          other ->
            other
        end

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # A human decision replaces the model's: same effect, `actor: :human`, confidence 1.
  defp override(_effect, result, :next), do: {:ok, result}

  defp override(%Effect{kind: :decide, args: args}, result, {:decide, value}) do
    type = Decision.type!(args.decision)

    if value in Type.values(type) do
      decision = %Decision{
        type: args.decision,
        type_version: type.version,
        value: value,
        confidence: 1.0,
        actor: :human,
        model: "human",
        probabilities: %{value => 1.0},
        input_hash: get_in(result, [:decision, :input_hash]),
        evidence: [%{replaced: replaced(result)}]
      }

      {:ok, %{value: value, decision: Decision.to_map(decision)}}
    else
      {:error, :invalid_value}
    end
  end

  defp override(_effect, _result, {:decide, _}), do: {:error, :not_a_decision}

  defp replaced(%{decision: d}) when is_map(d), do: Map.take(d, [:value, :confidence, :actor])
  defp replaced(result), do: Map.take(result, [:value])

  defp summary(%Effect{kind: :decide, args: args}, %{decision: d}) do
    %{
      "decision" => inspect(args.decision),
      "value" => d[:value],
      "confidence" => d[:confidence],
      "actor" => d[:actor]
    }
  end

  defp summary(%Effect{kind: :bash}, %{exit_status: status}), do: %{"exit_status" => status}
  defp summary(%Effect{kind: kind}, _result), do: %{"kind" => kind}

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
        # Leaving a state makes the effects still in flight stale; an internal transition
        # (nothing exited or entered) keeps waiting for them.
        in_flight = if step.exited == [] and step.entered == [], do: data.effects, else: %{}
        {effects, data} = number_effects(step.effects, %{data | ctx: step.ctx, effects: in_flight})

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
      tasks =
        for effect <- effects,
            pid = Effects.dispatch(data.runner, effect, self(), log: data.log, run_id: data.run_id, debug: data.debug),
            into: data.tasks,
            do: {effect.id, pid}

      data = %{data | effects: Map.merge(data.effects, Map.new(effects, &{&1.id, &1})), tasks: tasks}
      {ms, timeout_event} = Machine.timeout(machine, leaf)
      actions = [{:state_timeout, ms, timeout_event} | reply(from, {:ok, leaf})]

      if from == :init,
        do: {:ok, leaf, data, [{:state_timeout, ms, timeout_event}]},
        else: {:next_state, leaf, data, actions}
    end
  end

  defp finish(leaf, data, from, status \\ nil, prefix \\ []) do
    status = status || if(leaf == :failed, do: :failed, else: :done)

    log!(
      data,
      prefix ++
        [
          Event.new("run_finished", {:run_finished, status, leaf, data.ctx}, %{
            "status" => status,
            "final_state" => leaf
          })
        ]
    )

    Log.put_object(data.log, data.run_id, "run", %{status: status}, "status")
    Budget.delete(data.run_id)

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

  defp decision_events(%Effect{kind: :decide, id: id}, %{decision: d}) do
    [
      Event.new(
        "decision_made",
        {:decision_made, id, d},
        %{
          "effect_id" => id,
          "decision_type" => inspect(d.type),
          "value" => d.value,
          "confidence" => d.confidence,
          "actor" => d.actor,
          "model" => d.model,
          "latency_ms" => d.latency_ms,
          "input_hash" => d.input_hash,
          "tokens_in" => Map.get(d.cost || %{}, :tokens_in),
          "tokens_out" => Map.get(d.cost || %{}, :tokens_out),
          "usd" => Map.get(d.cost || %{}, :usd),
          "joules_est" => Map.get(d.cost || %{}, :joules_est)
        },
        [{id, "effect", "of"}]
      )
    ]
  end

  defp decision_events(_effect, _result), do: []

  # The actor of an event produced by an effect: the decider for decisions, else code.
  # The actor of an event produced by an effect: the decider for decisions, the chat model's tier
  # for a chat turn (its output chooses the next transition), else code. This is what the
  # determinism budget counts (docs/architecture/01-principles.md#2-the-determinism-budget).
  defp actor(_effect, %{decision: %{actor: actor}}) when actor not in [nil, :none], do: actor
  defp actor(%Effect{kind: :chat}, %{error: _}), do: :code
  defp actor(%Effect{kind: :chat}, _result), do: :local
  defp actor(_effect, _result), do: :code

  defp entered_event(state), do: Event.new("state_entered", {:state_entered, state}, %{"state" => state})

  defp exited_event(state), do: Event.new("state_exited", {:state_exited, state}, %{"state" => state})

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
    Xeito.Events.publish(data.run_id, events)
    :ok
  end
end
