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

  test "the first script of a fresh VM reaches every allowed module: JSON decodes and encodes", %{sandbox: sandbox} do
    code = ~s|JSON.decode!(~s({"a": [1, 2]})) \|> Map.update!("a", &Enum.sum/1) \|> JSON.encode!()|
    assert {{:ok, ~s({"a":3}), ""}, sandbox, []} = eval(sandbox, code)
    assert {{:ok, "{:error, " <> _, ""}, _sandbox, []} = eval(sandbox, ~s|JSON.decode("nope")|)
  end

  test "a script that raises on a megabyte value fails with the exception, not a limit", %{sandbox: sandbox} do
    # As a CI log: tabs, quotes and escape codes, which a report of the value would have to escape.
    line = "Ubuntu 24.04, OTP 27.3\tUNKNOWN STEP\t2026-10-28T14:58:39Z \e[31m** (MatchError) no match: \"x\"\e[0m\n"
    big = String.duplicate(line, div(1_000_000, byte_size(line)))
    on_call = fn "read", ["big.log"], acc -> {%{"ok" => true, "content" => big}, acc} end

    assert {{:error, %{type: :exception, message: "** (MatchError) no match of right hand side value" <> _}}, _, []} =
             eval(sandbox, ~s|%{content: c} = Script.read("big.log")|, %{}, on_call)
  end

  test "values the protocol cannot carry come back inspected; a script past its time is a timeout", %{sandbox: sandbox} do
    assert {{:ok, "{1, 2}", ""}, sandbox, []} = eval(sandbox, "{1, 2}")

    # The wait for a call counts: Dune's own clock ends the script, and the VM goes on.
    slow = fn "now", [], acc -> {Process.sleep(300) && 0, acc} end
    assert {{:error, %{type: :timeout}}, %{}, []} = eval(sandbox, "Script.now()", %{"timeout_ms" => 100}, slow)
  end

  test "a VM that dies mid-script is reported as crashed, and the sandbox is gone", %{sandbox: sandbox} do
    # Killed outright: a VM told to stop would still answer the call before it ends.
    killer = fn "now", [], acc ->
      :ok = :exec.kill(sandbox.os_pid, 9)
      {0, acc}
    end

    assert {{:error, %{type: type}}, nil, []} = eval(sandbox, "Script.now()", %{}, killer)
    assert type in [:crashed, :protocol]
  end
end
