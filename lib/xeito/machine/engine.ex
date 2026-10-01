defmodule Xeito.Machine.Engine do
  @moduledoc """
  Pure statechart semantics over a `%Xeito.Machine{}`: no processes, no I/O.

  `Xeito.Run` uses the engine live, and `Xeito.Run.Recovery` folds logged events through the
  same functions to rebuild a run. Because guards and actions are pure, both paths produce the
  same state.

  The active configuration is always one *leaf* state. On an event, the leaf's transitions
  are tried first, then its ancestors' (the event bubbles up). The first transition whose
  guard passes wins. Exited and entered states are computed relative to the least common
  ancestor. A self-transition exits and re-enters the state. A `:timeout` event that no
  transition handles moves the run to `:failed`.
  """

  alias Xeito.Effect
  alias Xeito.Machine
  alias Xeito.Machine.Transition

  @type step :: %{
          from: Machine.state_name(),
          to: Machine.state_name(),
          event: term(),
          exited: [Machine.state_name()],
          entered: [Machine.state_name()],
          ctx: map(),
          effects: [Effect.t()],
          implicit: boolean()
        }

  @doc "Enters the initial configuration. Returns the active leaf, entered states and entry effects."
  @spec start(Machine.t(), map()) :: %{
          leaf: Machine.state_name(),
          entered: [Machine.state_name()],
          ctx: map(),
          effects: [Effect.t()]
        }
  def start(%Machine{} = machine, ctx) when is_map(ctx) do
    leaf = Machine.leaf(machine, machine.initial)
    entered = machine |> Machine.lineage(leaf) |> Enum.reverse()
    %{leaf: leaf, entered: entered, ctx: ctx, effects: entry_effects(machine, entered, ctx)}
  end

  @doc "Handles one event in `leaf`. Returns the step taken, or `:ignored`."
  @spec handle(Machine.t(), Machine.state_name(), map(), term(), term()) ::
          {:ok, step()} | :ignored
  def handle(%Machine{} = machine, leaf, ctx, event, data) do
    if Machine.final?(machine, leaf) do
      :ignored
    else
      case select(machine, leaf, ctx, event, data) do
        nil when event == :timeout ->
          {:ok, take(machine, leaf, ctx, %Transition{event: :timeout, to: :failed}, data, true)}

        nil ->
          :ignored

        transition ->
          {:ok, take(machine, leaf, ctx, transition, data, false)}
      end
    end
  end

  @doc "Entry effects of `states` (outermost first), including decision requests."
  @spec entry_effects(Machine.t(), [Machine.state_name()], map()) :: [Effect.t()]
  def entry_effects(machine, states, ctx) do
    Enum.flat_map(states, fn name ->
      state = Machine.state!(machine, name)
      entry = if state.entry, do: apply(machine.module, state.entry, [ctx]), else: []

      decision =
        if state.decision,
          do: [Effect.decide(state.decision, decision_input(machine, state, ctx))],
          else: []

      List.wrap(entry) ++ decision
    end)
  end

  defp decision_input(_machine, %{decision_input: nil}, ctx), do: ctx
  defp decision_input(machine, %{decision_input: fun}, ctx), do: apply(machine.module, fun, [ctx])

  defp select(machine, leaf, ctx, event, data) do
    machine
    |> Machine.lineage(leaf)
    |> Enum.flat_map(&Machine.state!(machine, &1).transitions)
    |> Enum.find(fn t -> t.event == event and guard_passes?(machine, t, ctx, data) end)
  end

  defp guard_passes?(_machine, %Transition{guard: nil}, _ctx, _data), do: true

  defp guard_passes?(machine, %Transition{guard: guard}, ctx, data), do: apply(machine.module, guard, [ctx, data]) == true

  defp take(machine, leaf, ctx, transition, data, implicit?) do
    ctx =
      if transition.action, do: apply(machine.module, transition.action, [ctx, data]), else: ctx

    target = Machine.leaf(machine, transition.to)
    {exited, entered} = exits_and_entries(machine, leaf, target, transition.to)

    %{
      from: leaf,
      to: target,
      event: transition.event,
      exited: exited,
      entered: entered,
      ctx: ctx,
      effects: entry_effects(machine, entered, ctx),
      implicit: implicit?
    }
  end

  defp exits_and_entries(_machine, leaf, leaf, leaf), do: {[leaf], [leaf]}

  defp exits_and_entries(machine, source, target, _declared_target) do
    source_chain = Machine.lineage(machine, source)
    target_chain = Machine.lineage(machine, target)
    {source_chain -- target_chain, Enum.reverse(target_chain -- source_chain)}
  end
end
