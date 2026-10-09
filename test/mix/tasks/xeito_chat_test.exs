defmodule Mix.Tasks.Xeito.ChatTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Xeito.Chat

  test "a typed line becomes a review answer, a prompt, or nothing" do
    assert Chat.request_for("y", "ses-1") == %{"cmd" => "approve", "session" => "ses-1"}
    assert Chat.request_for("n", "ses-1") == %{"cmd" => "deny", "session" => "ses-1"}
    assert Chat.request_for("/help", "ses-1") == %{"cmd" => "prompt", "session" => "ses-1", "text" => "/help"}
    assert Chat.request_for("", "ses-1") == nil
  end

  test "a line ending in \\ continues the prompt on the next line" do
    assert Chat.take_line("", "first\\\n") == {:more, "first\n"}
    assert Chat.take_line("first\n", "second\r\n") == {:done, "first\nsecond"}
    assert Chat.take_line("", "plain\n") == {:done, "plain"}
  end

  test "opening starts a session in the workspace, or attaches to one" do
    cwd = Path.expand("w")
    assert Chat.open_request(cwd: "w") == %{"cmd" => "start", "cwd" => cwd}
    assert Chat.open_request(session: "ses-1", cwd: "w") == %{"cmd" => "attach", "session" => "ses-1", "cwd" => cwd}
    assert Chat.open_request([]) == %{"cmd" => "start", "cwd" => Path.expand(".")}
  end

  describe "run/1: the line-mode client against a daemon" do
    import ExUnit.CaptureIO

    setup do
      dir = Path.join(System.tmp_dir!(), "xeito-chattask-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      socket = Path.join(dir, "x.sock")
      log = Xeito.Case.start_log!()

      start_supervised!(
        {Xeito.Api, socket: socket, name: :"api_#{System.unique_integer([:positive])}", session: [log: log]}
      )

      %{socket: socket, ws: dir}
    end

    test "sends lines; a review answer with nothing waiting is shown as an error; the end of input quits", ctx do
      out = capture_io("y\n\n", fn -> Chat.run(["--socket", ctx.socket, "--cwd", ctx.ws]) end)
      assert out =~ ~r/session ses-\w+ · \/help/
      assert out =~ "nothing_to_approve"
    end

    test "a prompt continued with \\ is sent as one prompt of several lines", ctx do
      # `y\` and an empty line are one prompt, "y\n": the answer y, with nothing waiting for it.
      out = capture_io("y\\\n\n", fn -> Chat.run(["--socket", ctx.socket, "--cwd", ctx.ws]) end)
      assert out =~ "nothing_to_approve"
    end

    test "/quit quits; events are shown as transcript lines until then", ctx do
      send(self(), {:xeito_event, %{"event" => "notice", "attrs" => %{"text" => "hello from the daemon"}}})
      out = capture_io("/quit\n", fn -> Chat.run(["--socket", ctx.socket, "--cwd", ctx.ws]) end)
      assert out =~ "hello from the daemon"
    end

    test "a lost daemon ends the client", ctx do
      send(self(), {:xeito_event, %{"event" => "disconnected"}})
      assert capture_io("", fn -> Chat.run(["--socket", ctx.socket, "--cwd", ctx.ws]) end) =~ "daemon disconnected"
    end

    test "no daemon at the socket is an error" do
      assert_raise Mix.Error, ~r/^no daemon at \/nonexistent/, fn -> Chat.run(["--socket", "/nonexistent/x.sock"]) end
    end
  end
end
