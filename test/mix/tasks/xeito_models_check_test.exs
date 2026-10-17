defmodule Mix.Tasks.Xeito.Models.CheckTest do
  # Uses Mix's shell and the application's tier configuration.
  use ExUnit.Case, async: false

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  test "without remote tiers there is nothing to check" do
    Mix.Tasks.Xeito.Models.Check.run([])
    assert_received {:mix_shell, :info, ["no remote tier is configured: nothing to check"]}
  end
end
