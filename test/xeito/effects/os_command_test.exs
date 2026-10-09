defmodule Xeito.Effects.OsCommandTest do
  use Xeito.Case, async: true

  alias Xeito.Effects.OsCommand

  setup do
    dir = Path.join(System.tmp_dir!(), "xeito-os-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{ws: dir}
  end

  # Starts a background child that would outlive the shell, and records its pid.
  @with_child "sleep 30 & echo $! > child.pid; wait"

  defp sh(cmd, ws, opts \\ []), do: OsCommand.run("sh", ["-c", cmd], [cd: ws] ++ opts)

  defp child_pid(ws) do
    path = Path.join(ws, "child.pid")
    eventually(fn -> File.exists?(path) and File.read!(path) =~ ~r/\d+\n/ end)
    path |> File.read!() |> String.trim()
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  test "returns the merged output and the exit status, run in the given directory", %{ws: ws} do
    assert {:exited, 0, "out\nerr\n"} = sh("echo out; echo err >&2", ws)
    assert {:exited, 3, ""} = sh("exit 3", ws)
    File.write!(Path.join(ws, "here.txt"), "")
    assert {:exited, 0, "here.txt\n"} = sh("ls", ws)
  end

  test "output is handed on as it arrives, in order, as well as returned", %{ws: ws} do
    test = self()
    on_output = &send(test, {:chunk, &1})

    assert {:exited, 0, output} = sh("echo one; sleep 0.2; echo two", ws, on_output: on_output)
    assert_received {:chunk, "one\n"}
    assert_received {:chunk, "two\n"}
    refute_received {:chunk, _}
    assert output == "one\ntwo\n"
  end

  test "a timeout returns the output so far and kills the command's children too", %{ws: ws} do
    assert {:timeout, output} = sh("echo started; " <> @with_child, ws, timeout: 300)
    assert output == "started\n"
    pid = child_pid(ws)
    eventually(fn -> not alive?(pid) end)
  end

  test "a group that ignores SIGTERM is killed after the grace period", %{ws: ws} do
    started = System.monotonic_time(:millisecond)
    assert {:timeout, _} = sh("trap '' TERM; " <> @with_child, ws, timeout: 200, grace: 1_000)
    assert System.monotonic_time(:millisecond) - started < 3_000
    pid = child_pid(ws)
    eventually(fn -> not alive?(pid) end)
  end

  test "when the process waiting for the command dies (a halt), the command's group is killed", %{ws: ws} do
    waiter = spawn(fn -> sh(@with_child, ws, timeout: 60_000) end)
    pid = child_pid(ws)
    assert alive?(pid)

    Process.exit(waiter, :kill)
    eventually(fn -> not alive?(pid) end)
  end

  test "a command killed by a signal exits 128 + the signal", %{ws: ws} do
    assert {:exited, 137, ""} = sh("kill -KILL $$", ws)
  end

  test "exits stay as they were: not trapped after the command, whatever it returned", %{ws: ws} do
    sh("exit 1", ws)
    refute Process.info(self(), :trap_exit) == {:trap_exit, true}
    refute_received {:EXIT, _, _}
  end

  test "an executable that does not exist raises, as System.cmd does", %{ws: ws} do
    assert_raise ErlangError, fn -> OsCommand.run("no-such-command-#{System.unique_integer()}", [], cd: ws) end
  end
end
