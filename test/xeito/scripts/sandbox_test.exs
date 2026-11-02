defmodule Xeito.Scripts.SandboxTest do
  # Starts a real second VM: not async, and a few seconds.
  use ExUnit.Case, async: false

  alias Xeito.Scripts.Sandbox

  @moduletag :sandbox

  setup do
    Process.flag(:trap_exit, true)
    {:ok, sandbox} = Sandbox.start()
    on_exit(fn -> Sandbox.stop(sandbox) end)
    %{sandbox: sandbox}
  end

  test "evaluates scripts in the other VM, serving their calls from here", %{sandbox: sandbox} do
    assert {{:ok, 3, "hi\n"}, sandbox} = Sandbox.eval(sandbox, ~s|IO.puts("hi"); 1 + 2|, %{}, fn _, _ -> nil end)

    on_call = fn "read", ["a.ex"] -> %{"ok" => true, "content" => "A"} end
    assert {{:ok, "A", ""}, sandbox} = Sandbox.eval(sandbox, ~s|Script.read("a.ex")["content"]|, %{}, on_call)

    assert {{:error, %{type: :restricted}}, _sandbox} =
             Sandbox.eval(sandbox, ~s|File.read!("x")|, %{}, fn _, _ -> nil end)
  end

  test "values the protocol cannot carry come back inspected; a script past its time is a timeout", %{sandbox: sandbox} do
    assert {{:ok, "{1, 2}", ""}, sandbox} = Sandbox.eval(sandbox, "{1, 2}", %{}, fn _, _ -> nil end)

    # The wait for a call counts: Dune's own clock ends the script, and the VM goes on.
    slow = fn "now", [] -> Process.sleep(300) && 0 end
    assert {{:error, %{type: :timeout}}, %{}} = Sandbox.eval(sandbox, "Script.now()", %{"timeout_ms" => 100}, slow)
  end

  test "a VM that dies mid-script is reported as crashed, and the sandbox is gone", %{sandbox: sandbox} do
    killer = fn "now", [] ->
      :exec.stop(sandbox.pid)
      0
    end

    assert {{:error, %{type: type}}, nil} = Sandbox.eval(sandbox, "Script.now()", %{}, killer)
    assert type in [:crashed, :protocol]
  end
end
