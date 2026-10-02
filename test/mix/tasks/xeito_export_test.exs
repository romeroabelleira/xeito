defmodule Mix.Tasks.Xeito.ExportTest do
  # Mix's shell is global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Xeito.Export

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  defp exported(args) do
    Export.run(args)
    assert_received {:mix_shell, :info, [text]}
    text
  end

  test "exports a machine as Mermaid by default, or as SCXML" do
    assert exported(["Xeito.Machines.RunTests"]) =~ "stateDiagram-v2"
    assert exported(~w(Xeito.Machines.RunTests --format scxml)) =~ "<scxml"
  end

  test "an unknown format is an error" do
    assert_raise Mix.Error, ~r/unknown format "dot"/, fn -> Export.run(~w(Xeito.Machines.RunTests --format dot)) end
  end
end
