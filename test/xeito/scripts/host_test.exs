defmodule Xeito.Scripts.HostTest do
  # Starts real sandbox VMs: not async, and a few seconds.
  use ExUnit.Case, async: false

  alias Xeito.Scripts.Host

  @moduletag :sandbox

  defp session, do: "host-test-#{System.unique_integer([:positive])}"
  defp eval(session, code), do: Host.eval(session, code, %{"timeout_ms" => 10_000}, [], fn _, _, acc -> {nil, acc} end)

  test "a session's first script starts its sandbox, later ones reuse it, and stop/1 ends it" do
    session = session()
    on_exit(fn -> Host.stop(session) end)

    assert Host.whereis(session) == nil
    assert {{:ok, 2, ""}, []} = eval(session, "1 + 1")
    host = Host.whereis(session)
    assert is_pid(host)

    assert {{:ok, "x", ""}, []} = eval(session, ~s|"x"|)
    assert Host.whereis(session) == host

    assert :ok = Host.stop(session)
    assert Host.whereis(session) == nil
    assert :ok = Host.stop(session)
  end

  test "a sandbox that died is replaced by the next script; the host stays" do
    session = session()
    on_exit(fn -> Host.stop(session) end)

    assert {{:ok, 1, ""}, []} = eval(session, "1")
    host = Host.whereis(session)
    %{sandbox: sandbox} = :sys.get_state(host)
    Xeito.Scripts.Sandbox.stop(sandbox)

    assert {{:ok, 2, ""}, []} = eval(session, "2")
    assert Host.whereis(session) == host
  end

  test "a host idle for its idle time ends itself; the VM's exit and stray output between scripts leave it running" do
    session = session()
    {:ok, host} = Host.start_link(session, idle_ms: 100)
    Process.unlink(host)
    assert {{:ok, 1, ""}, []} = eval(session, "1")
    %{sandbox: %{pid: vm}} = :sys.get_state(host)

    send(host, {:stdout, 0, "late output"})
    send(host, {:EXIT, spawn(fn -> :ok end), :normal})
    assert %{sandbox: %{pid: ^vm}} = :sys.get_state(host)

    send(host, {:EXIT, vm, :killed})
    assert %{sandbox: nil} = :sys.get_state(host)

    ref = Process.monitor(host)
    assert_receive {:DOWN, ^ref, :process, ^host, :normal}, 1_000
    assert Host.whereis(session) == nil
  end

  test "the accumulator threads through the script's calls and comes back with the outcome" do
    session = session()
    on_exit(fn -> Host.stop(session) end)

    on_call = fn "text", [value], acc -> {value, [value | acc]} end
    code = ~s|Script.text("a"); Script.text("b"); :ok|
    assert {{:ok, "ok", ""}, ["b", "a"]} = Host.eval(session, code, %{}, [], on_call)
  end
end
