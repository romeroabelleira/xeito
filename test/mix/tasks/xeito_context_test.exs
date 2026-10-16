defmodule Mix.Tasks.Xeito.ContextTest do
  # Uses Mix's shell.
  use ExUnit.Case, async: false

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  test "measures the repository's task set, every file of which exists" do
    Mix.Tasks.Xeito.Context.run([])
    assert_received {:mix_shell, :info, [text]}
    assert text =~ ~r/^always read: \d+ tokens/
    assert text =~ "add a slash command"
    refute text =~ "missing:"
  end
end
