defmodule Mix.Tasks.Xeito.TuiTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Xeito.Tui

  @tag :tmp_dir
  test "config/1: the TUI's settings from the command line, for a daemon that is there", %{tmp_dir: dir} do
    socket = Path.join(System.tmp_dir!(), "xt-#{System.unique_integer([:positive])}.sock")
    {:ok, _listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket}, active: false])
    on_exit(fn -> File.rm(socket) end)

    assert Tui.config(["--socket", socket, "--cwd", dir, "--session", "ses-1", "--no-status-bar"]) ==
             [socket: socket, cwd: dir, session: "ses-1", status_bar: false]

    assert Tui.config(["--socket", socket]) == [socket: socket, cwd: File.cwd!(), session: nil, status_bar: true]
  end

  test "config/1: no daemon at the socket is an error" do
    assert_raise Mix.Error, ~r/^no daemon at \/nonexistent\/x.sock/, fn ->
      Tui.config(["--socket", "/nonexistent/x.sock"])
    end
  end

  test "config/1: a socket file nobody listens on, left by a daemon that died, is no daemon" do
    socket = Path.join(System.tmp_dir!(), "xt-#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> File.rm(socket) end)
    {:ok, stale} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket}, active: false])
    :ok = :gen_tcp.close(stale)

    assert_raise Mix.Error, ~r/^no daemon at /, fn -> Tui.config(["--socket", socket]) end
  end
end
