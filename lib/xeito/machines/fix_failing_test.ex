defmodule Xeito.Machines.FixFailingTest do
  @moduledoc """
  Reproduces a failing test, triages it, and loops plan → edit → verify until the tests pass.

  `triage` requests the typed decision `Xeito.Decisions.Triage` over the last failure
  (`triage_input/1`). In `working`, the fix is made either

    * by a human or an external agent, who sends `:planned` and `:edited`, or
    * with `delegate: true` (the harness), by a child run of `Xeito.Machines.Chat` started on
      entering `planning`, which gets the failure and the triage and ends with `:child_done`.

  Context: `%{cwd: path, test_cmd: "mix test", max_attempts: 3, max_reruns: 2}`, plus optional
  `:test_name`, `:diff_stat`, `:delegate`, and for the delegate `:system` and `:max_steps`.

  The diagram in `docs/architecture/02-state-machine-core.md` is generated from this module
  (`mix xeito.export`), and a test keeps the two in sync.
  """

  use Xeito.Machine, version: "0.5.0"

  alias Xeito.Effect

  @tests_timeout 900_000
  @work_timeout 3_600_000

  initial :reproduce

  state :reproduce, entry: :run_tests, timeout: @tests_timeout do
    on :ran, to: :triage, guard: :failed?, action: :record_failure
    on :ran, to: :done
  end

  state :triage do
    decide(Xeito.Decisions.Triage, input: :triage_input)
    on {:decided, :flaky}, to: :rerun
    on {:decided, :code_bug}, to: :working, action: :record_triage
    on {:decided, :test_bug}, to: :working, action: :record_triage
    on {:decided, :env_problem}, to: :ask_human
    on {:decided, :abstain}, to: :ask_human
  end

  state :rerun, entry: :run_tests, timeout: @tests_timeout do
    on :ran, to: :done, guard: :passed?
    on :ran, to: :triage, guard: :reruns_left?, action: :count_rerun_and_record
    on :ran, to: :failed
  end

  state :working, initial: :planning do
    on :give_up, to: :failed

    state :planning, entry: :maybe_delegate, timeout: @work_timeout do
      on :planned, to: :editing
      on :child_done, to: :verifying, guard: :fixed_by_child?, action: :record_fix
      on :child_done, to: :ask_human, action: :record_fix
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
  def maybe_delegate(%{delegate: true} = ctx) do
    [Effect.machine(Xeito.Machines.Chat, delegate_input(ctx), timeout: @work_timeout)]
  end

  def maybe_delegate(_ctx), do: []

  defp delegate_input(ctx) do
    prompt = """
    The test command `#{Map.get(ctx, :test_cmd, "mix test")}` fails.
    Triage: #{Map.get(ctx, :triage, "unknown")}. Attempt #{Map.get(ctx, :attempts, 0) + 1}.
    Fix the cause with the smallest correct change. Do not run the full test suite yourself;
    it is run after you answer. Answer with one sentence describing the fix.

    Failure output:
    #{Map.get(ctx, :last_failure, "")}
    """

    %{cwd: ctx.cwd, prompt: prompt, max_steps: Map.get(ctx, :max_steps, 25)}
    |> then(&if(ctx[:system], do: Map.put(&1, :system, ctx.system), else: &1))
  end

  @doc false
  def fixed_by_child?(_ctx, result), do: result[:state] == :answered

  @doc false
  def record_fix(ctx, result) do
    answer = get_in(result, [:ctx, :answer])
    Map.put(ctx, :fix, %{run_id: result[:run_id], state: result[:state], answer: answer})
  end

  @doc false
  def record_triage(ctx, result), do: Map.put(ctx, :triage, result[:value])

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
  def count_rerun_and_record(ctx, result),
    do: ctx |> Map.update(:reruns, 1, &(&1 + 1)) |> record_failure(result)

  @doc false
  def record_failure(ctx, result), do: Map.put(ctx, :last_failure, Map.get(result, :output, ""))

  @doc false
  def triage_input(ctx) do
    %{
      test: Map.get(ctx, :test_name, Map.get(ctx, :test_cmd, "test suite")),
      output: Map.get(ctx, :last_failure, ""),
      diff_stat: Map.get(ctx, :diff_stat, "")
    }
  end
end
