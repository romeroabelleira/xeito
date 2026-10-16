defmodule Xeito.Machines.Shell do
  @moduledoc """
  Runs one shell command the user typed (`/run <command>`) in the workspace, with no model and no review.

  Input: `%{cwd: path, cmd: "mix compile"}`. Ends `:done` on exit 0, else `:failed`, with
  `:exit_status` and `:report` (the output shaped as a `bash` result, headed by the status).
  """

  use Xeito.Machine, version: "0.1.0"

  alias Xeito.Effect

  @timeout 900_000

  initial :running

  # Outlasts the command's timeout, so a slow command ends with exit 124, not a state timeout.
  state :running, entry: :run_command, timeout: @timeout + 60_000 do
    on :ran, to: :done, guard: :succeeded?, action: :record
    on :ran, to: :failed, action: :record
  end

  final :done
  final :failed

  @doc false
  def run_command(ctx), do: [Effect.bash(ctx.cmd, cwd: ctx.cwd, timeout: @timeout)]

  @doc false
  def succeeded?(_ctx, result), do: result.exit_status == 0

  @doc false
  def record(ctx, %{exit_status: status} = result) do
    report = Map.get(result, :shaped) || String.trim_trailing("exit status #{status}\n" <> result.output)
    Map.merge(ctx, %{exit_status: status, report: report})
  end
end
