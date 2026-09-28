defmodule Xeito.Run.Recovery do
  @moduledoc """
  Rebuilds a run from its logged events (event sourcing).

  The run's input and every received event are folded through `Xeito.Machine.Engine`, the same
  pure functions the live run uses, so the rebuilt leaf state and context equal the ones before
  the crash. Effects requested in the current configuration that have no logged result are
  returned as *pending*. The run re-dispatches them (at-least-once delivery).

  Replay also checks itself, like the state checksums of rollback netcode: every effect the
  replay requests must equal the effect the log recorded at that point (for a chat call, the
  exact messages the model saw). The first mismatch is returned as `desync` (an effect id); the
  run refuses to recover from it rather than re-sending a different request.
  """

  alias Xeito.Machine
  alias Xeito.Machine.Engine

  @type rebuilt :: %{
          leaf: Machine.state_name(),
          ctx: map(),
          effect_count: non_neg_integer(),
          pending: [Xeito.Effect.t()],
          finished: boolean(),
          replayed: non_neg_integer(),
          desync: String.t() | nil
        }

  @doc "Rebuilds from `[{seq, type, term}]` entries of one run."
  @spec rebuild(module(), [{pos_integer(), String.t(), term()}]) ::
          {:ok, rebuilt()} | {:error, term()}
  def rebuild(module, [{_, "run_started", {:run_started, module, version, input}} | rest]) do
    machine = Machine.fetch!(module)

    if machine.version == version do
      started = Engine.start(machine, input)

      acc = %{
        leaf: started.leaf,
        ctx: started.ctx,
        effect_count: length(started.effects),
        requested: %{},
        order: [],
        expected: started.effects,
        finished: false,
        replayed: 0,
        desync: nil
      }

      {:ok, rest |> Enum.reduce(acc, &fold(machine, &1, &2)) |> finish()}
    else
      {:error, {:version_mismatch, logged: version, current: machine.version}}
    end
  end

  def rebuild(_module, []), do: {:error, :not_found}
  def rebuild(_module, [first | _]), do: {:error, {:unexpected_first_event, first}}

  defp fold(machine, {_, "event_received", {:event, name, data, _actor}}, acc) do
    acc = %{acc | replayed: acc.replayed + 1}

    case Engine.handle(machine, acc.leaf, acc.ctx, name, data) do
      :ignored ->
        acc

      {:ok, step} ->
        %{
          acc
          | leaf: step.to,
            ctx: step.ctx,
            effect_count: acc.effect_count + length(step.effects),
            requested: %{},
            order: [],
            expected: step.effects
        }
    end
  end

  defp fold(_machine, {_, "effect_requested", {:effect_requested, effect}}, acc) do
    acc = check(acc, effect)
    %{acc | requested: Map.put(acc.requested, effect.id, effect), order: [effect.id | acc.order]}
  end

  defp fold(_machine, {_, "effect_completed", {:effect_completed, id, _result}}, acc) do
    %{acc | requested: Map.delete(acc.requested, id)}
  end

  defp fold(_machine, {_, "run_finished", _}, acc), do: %{acc | finished: true}
  defp fold(_machine, _other, acc), do: acc

  # The logged effects follow the step that requested them, in order.
  defp check(%{expected: [expected | rest]} = acc, logged) do
    same = %{expected | id: logged.id} == logged
    %{acc | expected: rest, desync: acc.desync || if(same, do: nil, else: logged.id)}
  end

  defp check(acc, logged), do: %{acc | desync: acc.desync || logged.id}

  defp finish(acc) do
    pending = acc.order |> Enum.reverse() |> Enum.flat_map(&List.wrap(acc.requested[&1]))

    acc
    |> Map.take([:leaf, :ctx, :effect_count, :finished, :replayed, :desync])
    |> Map.put(:pending, pending)
  end
end
