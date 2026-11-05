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

  defp eval(sandbox, code, limits \\ %{}, on_call \\ fn _, _, acc -> {nil, acc} end),
    do: Sandbox.eval(sandbox, code, limits, [], on_call)

  test "evaluates scripts in the other VM, serving their calls from here", %{sandbox: sandbox} do
    assert {{:ok, 3, "hi\n"}, sandbox, []} = eval(sandbox, ~s|IO.puts("hi"); 1 + 2|)

    on_call = fn "read", [path], calls -> {%{"ok" => true, "content" => "A"}, [path | calls]} end
    assert {{:ok, "A", ""}, sandbox, ["a.ex"]} = eval(sandbox, ~s|{:ok, text} = Script.read("a.ex"); text|, %{}, on_call)

    assert {{:error, %{type: :restricted}}, _sandbox, []} = eval(sandbox, ~s|File.read!("x")|)
  end

  test "values the protocol cannot carry come back inspected; a script past its time is a timeout", %{sandbox: sandbox} do
    assert {{:ok, "{1, 2}", ""}, sandbox, []} = eval(sandbox, "{1, 2}")

    # The wait for a call counts: Dune's own clock ends the script, and the VM goes on.
    slow = fn "now", [], acc -> {Process.sleep(300) && 0, acc} end
    assert {{:error, %{type: :timeout}}, %{}, []} = eval(sandbox, "Script.now()", %{"timeout_ms" => 100}, slow)
  end

  test "a VM that dies mid-script is reported as crashed, and the sandbox is gone", %{sandbox: sandbox} do
    killer = fn "now", [], acc ->
      :exec.stop(sandbox.pid)
      {0, acc}
    end

    assert {{:error, %{type: type}}, nil, []} = eval(sandbox, "Script.now()", %{}, killer)
    assert type in [:crashed, :protocol]
  end
end
