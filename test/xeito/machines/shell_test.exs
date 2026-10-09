defmodule Xeito.Machines.ShellTest do
  use Xeito.Case, async: true

  alias Xeito.Machine
  alias Xeito.Machine.Engine
  alias Xeito.Machines.Shell

  @ctx %{cwd: "/tmp/ws", cmd: "mix compile"}

  test "runs the command once, in the workspace, with a long timeout" do
    assert [%Xeito.Effect{kind: :bash, args: %{cmd: "mix compile", cwd: "/tmp/ws", timeout: timeout}}] =
             Shell.run_command(@ctx)

    assert timeout >= 600_000
    # The command's own timeout ends it first (exit 124), not the state's.
    assert {state_ms, _event} = Machine.timeout(Machine.fetch!(Shell), :running)
    assert state_ms > timeout
  end

  test "exit 0 is done, anything else failed; both keep the exit status and output" do
    machine = Machine.fetch!(Shell)

    assert {:ok, %{to: :done, ctx: %{exit_status: 0, report: "exit status 0\nok"}}} =
             Engine.handle(machine, :running, @ctx, :ran, %{exit_status: 0, output: "ok\n"})

    assert {:ok, %{to: :failed, ctx: %{exit_status: 2, report: "exit status 2\nboom"}}} =
             Engine.handle(machine, :running, @ctx, :ran, %{exit_status: 2, output: "boom"})
  end

  test "the report is the shaped output when there is one: what a model would read" do
    shaped = "exit status 1\nfirst\n… 300 similar lines\nlast\n[shaped: …]"

    assert %{report: ^shaped, exit_status: 1} =
             Shell.record(@ctx, %{exit_status: 1, output: "long", shaped: shaped})
  end

  test "a command without output reports only its exit status" do
    assert %{report: "exit status 0"} = Shell.record(@ctx, %{exit_status: 0, output: ""})
  end
end
