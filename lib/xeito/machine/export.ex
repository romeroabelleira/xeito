defmodule Xeito.Machine.Export do
  @moduledoc """
  Exports a `%Xeito.Machine{}` as a Mermaid `stateDiagram-v2` or as W3C SCXML.

  Mermaid cannot draw an edge from a state nested inside a composite to a state outside it.
  Such transitions are therefore drawn from the outermost ancestor below the common level,
  e.g. `verifying → done` inside `working` becomes `working --> done`. Guards appear in
  brackets. The implicit timeout → `failed` safety net is not drawn.
  """

  alias Xeito.Machine

  @doc "Mermaid `stateDiagram-v2` source."
  @spec mermaid(Machine.t()) :: String.t()
  def mermaid(%Machine{} = machine) do
    edges = Enum.group_by(all_edges(machine), fn {parent, _from, _to, _label} -> parent end)
    lines = ["stateDiagram-v2" | block(machine, nil, edges, "  ")]
    Enum.join(lines, "\n") <> "\n"
  end

  defp block(machine, parent, edges, indent) do
    initial = if parent, do: Machine.state!(machine, parent).initial, else: machine.initial
    children = Machine.children(machine, parent)

    nested =
      children
      |> Enum.filter(&Machine.compound?(machine, &1))
      |> Enum.flat_map(fn name ->
        ["#{indent}state #{name} {"] ++
          block(machine, name, edges, indent <> "  ") ++ ["#{indent}}"]
      end)

    own_edges =
      for {_, from, to, label} <- Map.get(edges, parent, []),
          do: "#{indent}#{from} --> #{to}#{label}"

    finals = for name <- children, Machine.final?(machine, name), do: "#{indent}#{name} --> [*]"

    ["#{indent}[*] --> #{initial}"] ++ own_edges ++ nested ++ finals
  end

  defp all_edges(machine) do
    for name <- machine.order, t <- Machine.state!(machine, name).transitions do
      {parent, from, to} = lift(machine, name, t.to)
      {parent, from, to, label(t)}
    end
  end

  # Finds the level where source and target are siblings.
  defp lift(machine, source, target) do
    s_path = machine |> Machine.lineage(source) |> Enum.reverse()
    t_path = machine |> Machine.lineage(target) |> Enum.reverse()
    k = common_prefix(s_path, t_path)
    parent = if k == 0, do: nil, else: Enum.at(s_path, k - 1)

    if source == target,
      do: {Machine.state!(machine, source).parent, source, target},
      else: {parent, Enum.at(s_path, k, source), Enum.at(t_path, k, target)}
  end

  defp common_prefix([x | xs], [x | ys]), do: 1 + common_prefix(xs, ys)
  defp common_prefix(_, _), do: 0

  defp label(t) do
    guard = if t.guard, do: " [#{t.guard}]", else: ""
    ": " <> event_label(t.event) <> guard
  end

  defp event_label({:decided, value}), do: "decided #{value}"
  defp event_label(event) when is_atom(event), do: Atom.to_string(event)

  defp event_label(event) when is_tuple(event), do: event |> Tuple.to_list() |> Enum.map_join(" ", &to_string/1)

  @doc "W3C SCXML document. Guards become `cond` names; tuple events are dot-joined."
  @spec scxml(Machine.t()) :: String.t()
  def scxml(%Machine{} = machine) do
    body = Enum.flat_map(Machine.roots(machine), &scxml_state(machine, &1, "  "))

    Enum.join(
      [
        ~s(<?xml version="1.0" encoding="UTF-8"?>),
        ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" ) <>
          ~s(name="#{esc(machine.name)}" initial="#{machine.initial}">),
        ~s(  <!-- #{esc(inspect(machine.module))} #{esc(machine.version)} -->)
        | body
      ] ++ ["</scxml>"],
      "\n"
    ) <> "\n"
  end

  defp scxml_state(machine, name, indent) do
    state = Machine.state!(machine, name)

    if state.final do
      [~s(#{indent}<final id="#{name}"/>)]
    else
      initial = if state.initial, do: ~s( initial="#{state.initial}"), else: ""
      {ms, event} = Machine.timeout(machine, name)
      timeout = [~s(#{indent}  <!-- timeout #{ms} ms raises #{esc(scxml_event(event))} -->)]
      transitions = Enum.map(state.transitions, &scxml_transition(&1, indent <> "  "))

      children =
        Enum.flat_map(Machine.children(machine, name), &scxml_state(machine, &1, indent <> "  "))

      [~s(#{indent}<state id="#{name}"#{initial}>)] ++
        timeout ++ transitions ++ children ++ ["#{indent}</state>"]
    end
  end

  defp scxml_transition(t, indent) do
    cond_attr = if t.guard, do: ~s( cond="#{esc(Atom.to_string(t.guard))}"), else: ""
    ~s(#{indent}<transition event="#{esc(scxml_event(t.event))}"#{cond_attr} target="#{t.to}"/>)
  end

  defp scxml_event(event) when is_atom(event), do: Atom.to_string(event)

  defp scxml_event(event) when is_tuple(event), do: event |> Tuple.to_list() |> Enum.map_join(".", &to_string/1)

  defp esc(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
