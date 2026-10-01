defmodule Xeito.Api.ConnectionTest do
  use Xeito.Case, async: false

  alias Xeito.Client

  setup do
    dir = Path.join(System.tmp_dir!(), "xc-#{System.unique_integer([:positive])}")
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "x.sock")

    start_supervised!(
      {Xeito.Api, socket: path, name: :"api_#{System.unique_integer([:positive])}", session: [log: start_log!()]}
    )

    {:ok, client} = Client.connect(path)
    %{client: client, path: path, ws: ws}
  end

  defp req(client, cmd, fields \\ %{}), do: Client.request(client, Map.put(fields, "cmd", cmd))
  defp start(client, ws), do: req(client, "start", %{"cwd" => ws})["session"]
  defp new_id, do: "ses-c-#{System.unique_integer([:positive])}"

  test "start opens a session in a workspace", %{client: client, ws: ws} do
    assert %{"ok" => true, "session" => "ses-" <> _ = id} = req(client, "start", %{"cwd" => ws})
    assert %{"ok" => true, "status" => %{"cwd" => ^ws}} = req(client, "status", %{"session" => id})
  end

  test "attach follows a live session, resumes a closed one, and needs a workspace to", %{client: client, ws: ws} do
    id = start(client, ws)
    assert %{"ok" => true, "session" => ^id, "status" => %{"cwd" => ^ws}} = req(client, "attach", %{"session" => id})

    gone = new_id()
    assert %{"ok" => false, "error" => "no such session"} = req(client, "attach", %{"session" => gone})
    assert %{"ok" => true, "session" => ^gone} = req(client, "attach", %{"session" => gone, "cwd" => ws})
    assert %{"ok" => true, "status" => %{"cwd" => ^ws}} = req(client, "resume", %{"session" => new_id(), "cwd" => ws})
  end

  test "session commands: prompt, review answers, status, history, workspace", %{client: client, ws: ws} do
    id = start(client, ws)
    session = %{"session" => id}
    assert %{"ok" => true} = req(client, "prompt", Map.put(session, "text", "/help"))
    assert %{"ok" => false, "error" => "nothing_to_approve"} = req(client, "approve", session)
    assert %{"ok" => false, "error" => "nothing_to_approve"} = req(client, "deny", session)
    assert %{"ok" => true, "history" => []} = req(client, "history", session)
    assert %{"ok" => true, "workspace" => %{"git" => nil}} = req(client, "workspace", session)
    assert %{"ok" => false, "error" => "no such session"} = req(client, "status", %{"session" => new_id()})
  end

  test "machines, sessions and the monitor", %{client: client, ws: ws} do
    id = start(client, ws)
    assert %{"ok" => true, "machines" => [_ | _]} = req(client, "machines", %{"cwd" => ws})
    assert %{"ok" => true, "machines" => [_ | _]} = req(client, "machines", %{"session" => id})
    assert %{"ok" => true, "sessions" => sessions} = req(client, "sessions")
    assert Enum.any?(sessions, &(&1["id"] == id))
    # A new subscriber gets a snapshot at once; with none left, the daemon stops polling.
    assert %{"ok" => true} = req(client, "monitor", %{"on" => true})
    assert_receive {:xeito_event, %{"event" => "monitor", "attrs" => %{"system" => _}}}, 2_000
    assert %{"ok" => true} = req(client, "monitor", %{"on" => false})
    refute Xeito.Monitor.polling?()
  end

  test "unknown or incomplete commands", %{client: client} do
    assert %{"ok" => false, "error" => "unknown or incomplete command fly"} = req(client, "fly")
    assert %{"ok" => false, "error" => "unknown or incomplete command prompt"} = req(client, "prompt")
  end

  test "a line without a command, or not JSON, gets an error; a blank line nothing", %{path: path} do
    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
    :ok = :gen_tcp.send(socket, "\n{\"x\": 1}\nnot json\n")
    assert {:ok, ~s({"error":"missing cmd","ok":false}\n)} = :gen_tcp.recv(socket, 0, 2_000)
    assert {:ok, ~s({"error":"invalid JSON","ok":false}\n)} = :gen_tcp.recv(socket, 0, 2_000)
  end
end
