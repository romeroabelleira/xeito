defmodule Xeito.Effects do
  @moduledoc """
  Dispatches a run's `Xeito.Effect` structs to a runner; the only place a run's effects are executed.

  The runner executes each effect in a supervised task and sends
  `{:xeito_effect, effect_id, result}` back. Runner specs:

    * `{Xeito.Effects.Local, opts}`: executes `bash`, `read`, `write` inside the workspace
    * `{Xeito.Effects.Fake, fun: fun}`: `fun.(effect)` returns the result (tests)
    * `:none`: nothing runs (replay, property tests)

  A runner that raises yields `error_result/2` instead of crashing.
  """

  alias Xeito.Effect

  @type runner_spec :: {module(), keyword()} | :none

  @doc """
  Runs `effect` in a task that sends `{:xeito_effect, id, result}` to `reply_to`; returns its pid, or `nil` for `:none`.

  `context` (`:log`, `:run_id`) is merged under the runner's own options.
  """
  @spec dispatch(runner_spec(), Effect.t(), pid(), keyword()) :: pid() | nil
  def dispatch(runner, effect, reply_to, context \\ [])
  def dispatch(:none, _effect, _reply_to, _context), do: nil

  def dispatch({runner, opts}, %Effect{} = effect, reply_to, context) do
    opts = Keyword.merge(context, opts)

    {:ok, pid} =
      Task.Supervisor.start_child(Xeito.EffectTasks, fn ->
        send(reply_to, {:xeito_effect, effect.id, safe_run(runner, effect, opts)})
      end)

    pid
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
