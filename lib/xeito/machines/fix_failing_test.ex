defmodule Xeito.Machines.FixFailingTest do
  @moduledoc """
  Reproduces a failing test, triages it, and loops plan → edit → verify until the tests pass.

  P1 drives it with code only. `triage` requests a typed decision (stubbed by the runner until
  P2), and `planning` / `editing` wait for `:planned` / `:edited` events from a model tier or a
  human. Context: `%{cwd: path, test_cmd: "mix test", max_attempts: 3, max_reruns: 2}`.

  The diagram in `docs/architecture/02-state-machine-core.md` is generated from this module
  (`mix xeito.export`), and a test keeps the two in sync.
  """

  use Xeito.Machine, version: "0.3.0"

  alias Xeito.Effect

  @tests_timeout 900_000
  @work_timeout 3_600_000

  initial :reproduce

  state :reproduce, entry: :run_tests, timeout: @tests_timeout do
    on :ran, to: :triage, guard: :failed?
    on :ran, to: :done
  end

  state :triage do
    decide :triage
    on {:decided, :flaky}, to: :rerun
    on {:decided, :code_bug}, to: :working
    on {:decided, :test_bug}, to: :working
    on {:decided, :env_problem}, to: :ask_human
    on {:decided, :abstain}, to: :ask_human
  end

  state :rerun, entry: :run_tests, timeout: @tests_timeout do
    on :ran, to: :done, guard: :passed?
    on :ran, to: :triage, guard: :reruns_left?, action: :count_rerun
    on :ran, to: :failed
  end

  state :working, initial: :planning do
    on :give_up, to: :failed

    state :planning, timeout: @work_timeout do
      on :planned, to: :editing
    end

    state :editing, timeout: @work_timeout do
      on :edited, to: :verifying
    end

    state :verifying, entry: :run_tests, timeout: @tests_timeout do
      on :ran, to: :done, guard: :passed?
      on :ran, to: :planning, guard: :attempts_left?, action: :count_attempt
      on :ran, to: :failed
    end
  end

  state :ask_human, timeout: 86_400_000 do
    on :answered, to: :working
    on :abort, to: :failed
  end

  final :done
  final :failed

  @doc false
  def run_tests(ctx),
    do: [Effect.bash(Map.get(ctx, :test_cmd, "mix test"), cwd: ctx.cwd, timeout: @tests_timeout)]

  @doc false
  def passed?(_ctx, result), do: result.exit_status == 0
  @doc false
  def failed?(ctx, result), do: not passed?(ctx, result)

  @doc false
  def attempts_left?(ctx, _result),
    do: Map.get(ctx, :attempts, 0) + 1 < Map.get(ctx, :max_attempts, 3)

  @doc false
  def count_attempt(ctx, _result), do: Map.update(ctx, :attempts, 1, &(&1 + 1))

  @doc false
  def reruns_left?(ctx, _result), do: Map.get(ctx, :reruns, 0) < Map.get(ctx, :max_reruns, 2)
  @doc false
  def count_rerun(ctx, _result), do: Map.update(ctx, :reruns, 1, &(&1 + 1))
end
