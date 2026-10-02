defmodule Mix.Tasks.Xeito.TuiTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Xeito.Tui

  @tag :tmp_dir
  test "config/1: the TUI's settings from the command line, for a daemon that is there", %{tmp_dir: dir} do
    socket = Path.join(dir, "x.sock")
    File.write!(socket, "")

    assert Tui.config(["--socket", socket, "--cwd", dir, "--session", "ses-1", "--no-status-bar"]) ==
             [socket: socket, cwd: dir, session: "ses-1", status_bar: false]

    assert Tui.config(["--socket", socket]) == [socket: socket, cwd: File.cwd!(), session: nil, status_bar: true]
  end

  test "config/1: no daemon at the socket is an error" do
    assert_raise Mix.Error, ~r/^no daemon at \/nonexistent\/x.sock/, fn ->
      Tui.config(["--socket", "/nonexistent/x.sock"])
    end
  end
end
