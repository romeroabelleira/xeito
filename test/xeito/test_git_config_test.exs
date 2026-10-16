defmodule Xeito.TestGitConfigTest do
  # The tests run git in temporary repositories. They read a git config of their own
  # (test/support/gitconfig), never the developer's global or system one, which may sign commits,
  # run hooks or set an identity. Set in config/config.exs, before the application starts, so it
  # also reaches commands run through erlexec, whose port inherits the environment at start.
  use ExUnit.Case, async: true

  alias Xeito.Effects.OsCommand

  setup do
    dir = Path.join(System.tmp_dir!(), "xeito-gitconfig-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {_, 0} = System.cmd("git", ["init", "-q"], cd: dir)
    {:ok, dir: dir}
  end

  test "git reads the tests' own config, not the developer's", %{dir: dir} do
    {out, 0} = System.cmd("git", ["config", "--show-origin", "--get", "commit.gpgsign"], cd: dir)
    assert out =~ "test/support/gitconfig"
    assert out =~ "false"
  end

  test "so do commands run through erlexec", %{dir: dir} do
    assert OsCommand.run("git", ["config", "--get", "commit.gpgsign"], cd: dir) == {:exited, 0, "false\n"}
  end

  test "a commit takes the tests' identity and branch, and is not signed even where signing would fail", %{dir: dir} do
    args = ["-c", "gpg.format=ssh", "-c", "gpg.ssh.program=/bin/false", "commit", "-q", "--allow-empty", "-m", "x"]
    assert {:exited, 0, _} = OsCommand.run("git", args, cd: dir)
    assert {"main\n", 0} = System.cmd("git", ["branch", "--show-current"], cd: dir)
  end
end
