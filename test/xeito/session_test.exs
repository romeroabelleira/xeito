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
end
