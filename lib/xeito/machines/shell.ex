defmodule Xeito.Machines.Shell do
  @moduledoc """
  Runs one shell command the user typed (`/run <command>`) in the workspace: no model and no
  review, since the user asked for it. Context: `%{cwd: path, cmd: "mix compile"}`.

  It ends `:done` when the command exits 0 and `:failed` otherwise, with `:exit_status` and
  `:report` in the context: the output as a model reads a `bash` result (`Xeito.Tools.Shape`),
  headed by the exit status. The session puts the report in the conversation, so the next turn
  can talk about it.
  """

  use Xeito.Machine, version: "0.1.0"

  alias Xeito.Effect

  @timeout 900_000

  initial :running

  # The state outlasts the command's own timeout: a slow command ends with exit 124 and its
  # output so far, not with a state timeout.
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
