defmodule Xeito.Machines.Check do
  @moduledoc """
  Runs the project's checks (format, lint, compile warnings, tests) and hands failures to a
  delegated chat run until they pass or the attempts are used up.

      checking ─┬─ passed ────────────────────────→ done
                ├─ failed, attempts left ─→ fixing ─(child_done)→ checking
                └─ failed, no attempts ───→ ask_human ─┬─ approved (fixed by hand) → checking
                                                       └─ denied → failed

  Unlike `Xeito.Machines.FixFailingTest` there is no triage: a formatter or linter failure
  names its own cause, and the fixing run reads the output directly.

  Input: `%{cwd: path, check_cmd: "mix ci"}`, optionally `max_attempts` (default 3), `system` and
  `max_steps` for the delegate.
  """

  use Xeito.Machine, version: "0.1.0"

  alias Xeito.Effect

  @check_timeout 900_000
  @fix_timeout 3_600_000
  @output_tail 6_000

  initial :checking

  state :checking, entry: :run_check, timeout: @check_timeout do
    on :ran, to: :done, guard: :passed?, action: :record_pass
    on :ran, to: :fixing, guard: :attempts_left?, action: :record_failure
    on :ran, to: :ask_human, action: :record_failure
  end

  state :fixing, entry: :delegate_fix, timeout: @fix_timeout do
    on :child_done, to: :checking, action: :count_attempt
  end

  state :ask_human, timeout: {86_400_000, :denied} do
    on :approved, to: :checking
    on :denied, to: :failed
  end

  final :done
  final :failed

  @doc false
  def run_check(ctx), do: [Effect.bash(ctx.check_cmd, cwd: ctx.cwd, timeout: @check_timeout)]

  @doc false
  def delegate_fix(ctx) do
    prompt = """
    The project's checks fail: `#{ctx.check_cmd}`. Attempt #{Map.get(ctx, :attempts, 0) + 1}.
    Fix the causes (formatting, warnings, lint findings, failing tests) with the smallest correct
    changes. Prefer the project's own fixers where they exist (for example `mix format`). Do not
    rerun the full checks yourself; they run after you answer. Answer with one sentence.

    Output (tail):
    #{Map.get(ctx, :last_failure, "")}
    """

    input =
      %{cwd: ctx.cwd, prompt: prompt, max_steps: Map.get(ctx, :max_steps, 25)}
      |> then(&if(ctx[:system], do: Map.put(&1, :system, ctx.system), else: &1))

    [Effect.machine(Xeito.Machines.Chat, input, timeout: @fix_timeout)]
  end

  @doc false
  def passed?(_ctx, result), do: result.exit_status == 0

  @doc false
  def attempts_left?(ctx, _result),
    do: Map.get(ctx, :attempts, 0) < Map.get(ctx, :max_attempts, 3)

  @doc false
  def record_failure(ctx, result) do
    output = result.output

    tail =
      binary_part(
        output,
        max(byte_size(output) - @output_tail, 0),
        min(byte_size(output), @output_tail)
      )

    Map.merge(ctx, %{last_failure: tail, review: "checks still fail: fix by hand, then approve"})
  end

  @doc false
  def record_pass(ctx, _result) do
    fixes = Map.get(ctx, :attempts, 0)

    Map.put(
      ctx,
      :answer,
      "Checks pass" <> if(fixes > 0, do: " after #{fixes} fix run(s).", else: ".")
    )
  end

  @doc false
  def count_attempt(ctx, _result), do: Map.update(ctx, :attempts, 1, &(&1 + 1))
end
