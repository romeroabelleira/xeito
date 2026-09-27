defmodule Xeito.Effects do
  @moduledoc """
  Effect descriptions returned by machines, executed by a policy-checked runner.

  A run never performs I/O itself. Its entry functions return `Xeito.Effect` structs, and the
  run hands them to a runner through `dispatch/3`. The runner executes each effect in a
  supervised task and sends the result back as `{:xeito_effect, effect_id, result}`. That one
  choke point is what makes replay, sandboxing and testing possible.

  Runner specs:

    * `{Xeito.Effects.Local, opts}` — really executes (`bash`, `read`, `write`) inside the
      workspace; `decide` is stubbed until P2 via `opts[:decide]`
    * `{Xeito.Effects.Fake, fun: fun}` — `fun.(effect)` returns the result (tests)
    * `:none` — effects are recorded but never executed (replay, property tests)

  See `docs/architecture/02-state-machine-core.md` and `docs/architecture/10-security-and-sandboxing.md`.
  """

  alias Xeito.Effect

  @type runner_spec :: {module(), keyword()} | :none

  @doc "Executes `effect` asynchronously and sends `{:xeito_effect, id, result}` to `reply_to`."
  @spec dispatch(runner_spec(), Effect.t(), pid()) :: :ok
  def dispatch(:none, _effect, _reply_to), do: :ok

  def dispatch({runner, opts}, %Effect{} = effect, reply_to) do
    {:ok, _pid} =
      Task.Supervisor.start_child(Xeito.EffectTasks, fn ->
        send(reply_to, {:xeito_effect, effect.id, safe_run(runner, effect, opts)})
      end)

    :ok
  end

  defp safe_run(runner, effect, opts) do
    runner.run(effect, opts)
  rescue
    error -> error_result(effect, Exception.message(error))
  end

  @doc "A result of the right shape for `effect` that reports `message` as an error."
  @spec error_result(Effect.t(), String.t()) :: map()
  def error_result(%Effect{kind: :bash}, message), do: %{exit_status: -1, output: message}
  def error_result(%Effect{kind: :decide}, message), do: %{value: :abstain, error: message}
  def error_result(%Effect{}, message), do: %{ok: false, error: message}
end
