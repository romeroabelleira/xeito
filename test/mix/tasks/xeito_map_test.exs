defmodule Mix.Tasks.Xeito.MapTest do
  # Uses Mix's shell.
  use ExUnit.Case, async: false

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  defp output(args) do
    Mix.Tasks.Xeito.Map.run(args)
    assert_received {:mix_shell, :info, [text]}
    text
  end

  test "every module, one line each" do
    text = output([])
    assert text =~ ~r/^Xeito  lib\/xeito.ex  /
    refute text =~ "\n  worst_case("
  end

  test "a prefix lists those modules with their functions" do
    text = output(["Xeito.Allowance"])
    assert text =~ "\n  verdict("
    refute text =~ "Xeito.Budget"
  end

  test "--functions lists every module's functions" do
    assert output(["--functions"]) =~ "\n  verdict("
  end
end
