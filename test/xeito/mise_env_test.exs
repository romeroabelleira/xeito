defmodule Xeito.MiseEnvTest do
  @moduledoc "Commands run with the tool versions mise pins for the workspace."
  # Sets which executables are installed (application environment).
  use ExUnit.Case, async: false

  alias Xeito.Effect
  alias Xeito.Effects.Local
  alias Xeito.Effects.MiseEnv

  # Not ExUnit's tmp_dir: that is inside this repository, whose own `.tool-versions` is above it.
  setup do
    dir = Path.join(System.tmp_dir!(), "xeito-mise-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:xeito, :executables)

    on_exit(fn ->
      Application.put_env(:xeito, :executables, previous)
      File.rm_rf(dir)
    end)

    ws = Path.join(dir, "project/sub")
    File.mkdir_p!(ws)
    %{ws: ws, dir: dir}
  end

  # A stand-in for mise: `exec -- cmd…` marks the output, then runs the command.
  defp fake_mise(dir, body \\ ~s(shift; shift; echo "[mise]"; exec "$@")) do
    path = Path.join(dir, "mise")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    Application.put_env(:xeito, :executables, %{"mise" => path})
    path
  end

  test "without mise configuration, a command runs in sh as before", %{ws: ws, dir: dir} do
    fake_mise(dir)
    assert MiseEnv.command(ws, "ruby -v") == {"sh", ["-c", "ruby -v"]}
  end

  test "with mise configuration in the workspace or above it, in mise exec", %{ws: ws, dir: dir} do
    mise = fake_mise(dir)

    for {where, file} <- [{ws, "mise.toml"}, {ws, ".mise.toml"}, {Path.dirname(ws), ".tool-versions"}] do
      File.write!(Path.join(where, file), "")
      assert MiseEnv.command(ws, "ruby -v") == {mise, ["exec", "--", "sh", "-c", "ruby -v"]}
      File.rm!(Path.join(where, file))
    end
  end

  test "without mise installed, configuration changes nothing", %{ws: ws} do
    Application.put_env(:xeito, :executables, %{"mise" => false})
    File.write!(Path.join(ws, "mise.toml"), "")
    assert MiseEnv.command(ws, "ruby -v") == {"sh", ["-c", "ruby -v"]}
  end

  test "a bash effect runs through mise", %{ws: ws, dir: dir} do
    fake_mise(dir)
    File.write!(Path.join(ws, ".tool-versions"), "ruby 3.4\n")
    assert %{exit_status: 0, output: "[mise]\nhi\n"} = Local.run(Effect.bash("echo hi", cwd: ws), [])
  end

  test "a configuration mise does not trust is said so, with what to do", %{ws: ws, dir: dir} do
    fake_mise(dir, ~s(echo "mise ERROR Config files in #{ws}/mise.toml are not trusted." >&2; exit 1))
    File.write!(Path.join(ws, "mise.toml"), "")

    assert %{exit_status: 1, output: output} = Local.run(Effect.bash("echo hi", cwd: ws), [])
    assert output =~ "are not trusted"
    assert output =~ "run `mise trust` in #{ws}"

    assert MiseEnv.explain("some other failure", 1, ws) == "some other failure"
    assert MiseEnv.explain("not trusted, but it worked", 0, ws) == "not trusted, but it worked"
  end
end
