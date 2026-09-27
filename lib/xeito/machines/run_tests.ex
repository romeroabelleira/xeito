defmodule Xeito.Machines.RunTests do
  @moduledoc """
  Runs the project's tests once. Context: `%{cwd: path, test_cmd: "mix test"}`.
  """

  use Xeito.Machine, version: "0.1.0"

  alias Xeito.Effect

  initial :running

  state :running, entry: :run_tests, timeout: 900_000 do
    on :ran, to: :done, guard: :passed?
    on :ran, to: :failed
  end

  final :done
  final :failed

  @doc false
  def run_tests(ctx),
    do: [Effect.bash(Map.get(ctx, :test_cmd, "mix test"), cwd: ctx.cwd, timeout: 900_000)]

  @doc false
  def passed?(_ctx, result), do: result.exit_status == 0
end
