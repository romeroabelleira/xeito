defmodule Xeito.Api.ConnectionTest do
  use Xeito.Case, async: false

  alias Xeito.Client

  setup do
    dir = Path.join(System.tmp_dir!(), "xc-#{System.unique_integer([:positive])}")
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "x.sock")

    log = start_log!()
    start_supervised!({Xeito.Api, socket: path, name: :"api_#{System.unique_integer([:positive])}", session: [log: log]})

    {:ok, client} = Client.connect(path)
    %{client: client, path: path, ws: ws, log: log}
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
    allow = &req(client, "approve", Map.put(session, "allow", &1))
    assert %{"ok" => false, "error" => "nothing_to_approve"} = allow.("session")
    assert %{"ok" => false, "error" => "nothing_to_approve"} = allow.("always")
    assert %{"ok" => false, "error" => "unknown_scope"} = allow.("forever")
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

  test "open continues the directory's last updated session, or starts one", %{client: client, ws: ws, log: log} do
    assert %{"ok" => true, "session" => first, "continued" => false} = req(client, "open", %{"cwd" => ws})
    assert %{"ok" => true} = req(client, "prompt", %{"session" => first, "text" => "/help"})
    assert %{"ok" => true, "session" => ^first, "continued" => true} = req(client, "open", %{"cwd" => ws})

    # A session the daemon does not hold (it restarted) is rebuilt from the log.
    gone = new_id()
    Xeito.Log.put_object(log, gone, "session", %{cwd: ws, status: "closed"})

    assert %{"ok" => true, "session" => ^gone, "continued" => true, "status" => %{"cwd" => ^ws}} =
             req(client, "open", %{"cwd" => ws})
  end

  test "a directory's sessions and prompts", %{client: client, ws: ws} do
    id = start(client, ws)
    assert %{"ok" => true} = req(client, "prompt", %{"session" => id, "text" => "/help"})

    assert %{"ok" => true, "sessions" => [%{"id" => ^id, "prompts" => 1, "last_prompt" => "/help", "live" => true}]} =
             req(client, "sessions", %{"cwd" => ws})

    assert %{"ok" => true, "prompts" => ["/help"]} = req(client, "prompts", %{"cwd" => ws})
    assert %{"ok" => true, "turns" => []} = req(client, "transcript", %{"session" => id, "cwd" => ws})

    assert %{"ok" => false, "error" => "unknown or incomplete command transcript"} =
             req(client, "transcript", %{"cwd" => ws})
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

  describe "the connection process" do
    defp connections, do: Xeito.ApiConnections |> DynamicSupervisor.which_children() |> Enum.map(&elem(&1, 1))

    defp new_connection(path) do
      # The setup's client connects asynchronously too; let it settle first.
      Process.sleep(100)
      before = connections()
      {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, packet: :line, active: false])
      Process.sleep(100)
      [conn] = connections() -- before
      {socket, conn}
    end

    test "a line longer than the limit, or a socket error, closes the connection; other messages are ignored", %{
      path: path
    } do
      {socket, conn} = new_connection(path)
      ref = Process.monitor(conn)

      send(conn, :something_else)
      assert Process.alive?(conn)

      :ok = :gen_tcp.send(socket, :binary.copy("x", 4_194_400))
      assert_receive {:DOWN, ^ref, :process, ^conn, :normal}, 2_000

      {_socket, other} = new_connection(path)
      ref = Process.monitor(other)
      send(other, {:tcp_error, :port, :closed})
      assert_receive {:DOWN, ^ref, :process, ^other, :normal}, 2_000
    end

    test "resuming a session that is already live just follows it", %{client: client, ws: ws} do
      id = start(client, ws)
      assert %{"ok" => true, "session" => ^id} = req(client, "resume", %{"session" => id, "cwd" => ws})
    end
  end

  test "a session that cannot start, in a workspace that is a file, is an error, for start and resume", %{ws: ws} do
    # Without a preconfigured log, a session opens its workspace's log, which fails here.
    path = Path.join(ws, "y.sock")

    start_supervised!({Xeito.Api, socket: path, name: :"api_#{System.unique_integer([:positive])}", session: []},
      id: :plain_api
    )

    {:ok, client} = Client.connect(path)
    file = Path.join(ws, "not-a-dir")
    File.write!(file, "")

    assert %{"ok" => false, "error" => _} = req(client, "start", %{"cwd" => file})
    assert %{"ok" => false, "error" => _} = req(client, "resume", %{"session" => new_id(), "cwd" => file})
  end
end
