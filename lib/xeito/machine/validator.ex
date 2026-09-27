defmodule Xeito.Machine.Validator do
  @moduledoc """
  Compile-time checks for machine definitions. A machine that fails validation does not compile.

  Checks:

    * the initial state exists; compound states name an existing direct child as `initial:`
    * transitions target existing states; final states have no transitions or children
    * a `:failed` final state exists (unhandled timeouts go there)
    * every state is reachable from the initial state (`:failed` always is, via timeouts)
    * a final state is reachable from every state through *declared* transitions
      (the implicit timeout → `:failed` safety net does not count)
    * states with `decide` handle at least one `{:decided, _}` event
    * entry functions (arity 1), guards and actions (arity 2) are public functions
  """

  alias Xeito.Machine

  @type defines? :: ({atom(), arity()} -> boolean())

  @spec validate(Machine.t(), defines?()) :: :ok | {:error, [String.t()]}
  def validate(%Machine{} = machine, defines?) do
    checks = [
      &check_initial/2,
      &check_compound/2,
      &check_finals/2,
      &check_targets/2,
      &check_functions/2,
      &check_decisions/2,
      &check_graph/2
    ]

    case Enum.flat_map(checks, & &1.(machine, defines?)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp check_initial(%Machine{initial: nil}, _), do: ["no initial state (use `initial :name`)"]

  defp check_initial(machine, _) do
    if Map.has_key?(machine.states, machine.initial),
      do: [],
      else: ["initial state #{inspect(machine.initial)} is not declared"]
  end

  defp check_compound(machine, _) do
    Enum.flat_map(machine.order, fn name ->
      state = machine.states[name]
      children = Machine.children(machine, name)

      cond do
        children == [] and state.initial ->
          ["#{inspect(name)} has `initial:` but no child states"]

        children != [] and state.initial not in children ->
          ["compound state #{inspect(name)} needs `initial:` naming one of #{inspect(children)}"]

        true ->
          []
      end
    end)
  end

  defp check_finals(machine, _) do
    finals = Enum.filter(machine.order, &machine.states[&1].final)

    missing_failed =
      if :failed in finals,
        do: [],
        else: ["a `final :failed` state is required (unhandled timeouts go there)"]

    malformed =
      Enum.flat_map(finals, fn name ->
        state = machine.states[name]

        if state.transitions != [] or Machine.compound?(machine, name),
          do: ["final state #{inspect(name)} cannot have transitions or children"],
          else: []
      end)

    missing_failed ++ malformed
  end

  defp check_targets(machine, _) do
    for name <- machine.order,
        t <- machine.states[name].transitions,
        not Map.has_key?(machine.states, t.to) do
      "#{inspect(name)}: transition on #{inspect(t.event)} targets undeclared state #{inspect(t.to)}"
    end
  end

  defp check_functions(machine, defines?) do
    Enum.flat_map(machine.order, fn name ->
      state = machine.states[name]

      entry = if state.entry, do: [{state.entry, 1, "entry"}], else: []
      callbacks = Enum.flat_map(state.transitions, &transition_functions/1)

      for {fun, arity, role} <- entry ++ callbacks, not defines?.({fun, arity}) do
        "#{inspect(name)}: #{role} #{fun}/#{arity} must be a public function of the machine module"
      end
    end)
  end

  defp transition_functions(t) do
    [{t.guard, 2, "guard"}, {t.action, 2, "action"}]
    |> Enum.reject(fn {fun, _, _} -> is_nil(fun) end)
  end

  defp check_decisions(machine, _) do
    for name <- machine.order,
        decision <- [machine.states[name].decision],
        decision != nil,
        not handles_decided?(machine, name) do
      "#{inspect(name)} decides #{inspect(decision)} but handles no {:decided, _} event"
    end
  end

  defp handles_decided?(machine, name) do
    machine
    |> Machine.lineage(name)
    |> Enum.flat_map(&machine.states[&1].transitions)
    |> Enum.any?(&match?({:decided, _}, &1.event))
  end

  defp check_graph(machine, _) do
    if Map.has_key?(machine.states, machine.initial) and structurally_sound?(machine) do
      unreachable(machine) ++ dead_ends(machine)
    else
      []
    end
  end

  defp structurally_sound?(machine) do
    check_compound(machine, nil) == [] and check_targets(machine, nil) == []
  end

  # Edges between *leaf* states: a leaf may take its own transitions and its ancestors'.
  defp edges(machine, leaf) do
    machine
    |> Machine.lineage(leaf)
    |> Enum.flat_map(&machine.states[&1].transitions)
    |> Enum.map(&Machine.leaf(machine, &1.to))
    |> Enum.uniq()
  end

  defp leaves(machine), do: Enum.reject(machine.order, &Machine.compound?(machine, &1))

  defp reachable(machine, from) do
    Stream.unfold({[from], MapSet.new([from])}, fn
      {[], _seen} ->
        nil

      {[s | rest], seen} ->
        next = Enum.reject(edges(machine, s), &MapSet.member?(seen, &1))
        {s, {rest ++ next, MapSet.union(seen, MapSet.new(next))}}
    end)
    |> MapSet.new()
  end

  defp unreachable(machine) do
    seen = reachable(machine, Machine.leaf(machine, machine.initial))

    # :failed is always reachable through the implicit timeout transition.
    for leaf <- leaves(machine), leaf != :failed, not MapSet.member?(seen, leaf) do
      "#{inspect(leaf)} is unreachable from the initial state"
    end
  end

  defp dead_ends(machine) do
    for leaf <- leaves(machine),
        not machine.states[leaf].final,
        not Enum.any?(reachable(machine, leaf), &machine.states[&1].final) do
      "no final state is reachable from #{inspect(leaf)} through declared transitions"
    end
  end
end
