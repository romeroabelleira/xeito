defmodule Xeito.SessionTest do
  use Xeito.Case, async: false

  alias Xeito.Session

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    log = start_log!()
    id = "ses-req-#{System.unique_integer([:positive])}"
    {:ok, ^id} = Session.start(cwd: ws, log: log, id: id)
    Session.subscribe(id)
    %{id: id, log: log, ws: ws}
  end

  defp stop(id) do
    [{pid, _}] = Registry.lookup(Xeito.SessionRegistry, id)
    ref = Process.monitor(pid)
    DynamicSupervisor.terminate_child(Xeito.SessionSupervisor, pid)
    assert_receive {:DOWN, ^ref, _, _, _}, 2_000
  end

  describe "a prompt with a request id is admitted once" do
    test "a repeat gets the same answer and does nothing", %{id: id, ws: ws} do
      assert :ok = Session.prompt(id, "/run touch a.txt", "r-1")
      assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
      File.rm!(Path.join(ws, "a.txt"))

      assert :ok = Session.prompt(id, "/run touch a.txt", "r-1")
      refute_receive {:xeito, _, %{type: "turn_finished"}}, 500
      refute File.exists?(Path.join(ws, "a.txt"))
    end

    test "another id, or none, is a new prompt", %{id: id, ws: ws} do
      assert :ok = Session.prompt(id, "/run touch a.txt", "r-1")
      assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
      assert :ok = Session.prompt(id, "/run touch b.txt", "r-2")
      assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
      assert :ok = Session.prompt(id, "/run touch c.txt")
      assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
      assert Enum.all?(~w(a b c), &File.exists?(Path.join(ws, "#{&1}.txt")))
    end

    test "also after the session is rebuilt from its log, as after a daemon restart", %{id: id, log: log, ws: ws} do
      assert :ok = Session.prompt(id, "/run touch a.txt", "r-1")
      assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
      File.rm!(Path.join(ws, "a.txt"))

      stop(id)
      {:ok, ^id} = Session.start(cwd: ws, log: log, id: id)
      Session.subscribe(id)

      assert :ok = Session.prompt(id, "/run touch a.txt", "r-1")
      refute_receive {:xeito, _, %{type: "turn_finished"}}, 500
      refute File.exists?(Path.join(ws, "a.txt"))
    end
  end

  describe "one_shot/3: a turn with its machine named, without routing" do
    test "starts the machine at once, with no intent decision", %{id: id, ws: ws} do
      assert :ok = Session.one_shot(id, "touch a.txt", machine: "shell")
      assert_receive {:xeito, _, %{type: "prompt", attrs: %{"text" => "touch a.txt"}}}, 2_000
      assert_receive {:xeito, _, %{type: "run_selected", attrs: %{"reason" => "one-shot machine:shell"}}}, 2_000
      assert_receive {:xeito, _, %{type: "turn_finished", attrs: %{"status" => :done}}}, 5_000
      refute_received {:xeito, _, %{type: "intent"}}
      assert File.exists?(Path.join(ws, "a.txt"))
    end

    test "refuses what it cannot start, and while a turn runs", %{id: id} do
      assert {:error, "unknown machine \"nope\"" <> _} = Session.one_shot(id, "x", machine: "nope")
      assert :ok = Session.one_shot(id, "sleep 5", machine: "shell")
      assert {:error, :busy} = Session.one_shot(id, "true", machine: "shell")
      assert {:error, :busy} = Session.close(id)
      :ok = Session.prompt(id, "/halt")
      assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
    end
  end

  test "dry_run/3: the first model request of a one-shot turn, sent nowhere", %{id: id} do
    assert {:ok, %{messages: [%{role: "system"}, %{role: "user", content: "hi"}], tools: []}} =
             Session.dry_run(id, "hi", [])

    refute_receive {:xeito, _, %{type: "prompt"}}, 200
    assert {:error, "unknown machine" <> _} = Session.dry_run(id, "hi", machine: "nope")
  end

  test "close/1 stops an idle session normally", %{id: id} do
    [{pid, _}] = Registry.lookup(Xeito.SessionRegistry, id)
    ref = Process.monitor(pid)
    assert :ok = Session.close(id)
    assert_receive {:DOWN, ^ref, _, _, :normal}, 2_000
  end
end
