defmodule Xeito.Scripts.VmTest do
  # One script runs at a time in a VM: the runner registers itself by name.
  use ExUnit.Case, async: false

  alias Xeito.Scripts.Vm

  defp run(code, on_call \\ fn _name, _args -> nil end), do: Vm.run(code, %{}, on_call)

  test "a script's last value comes back, with what it printed" do
    assert {:ok, 3, "hi\n"} = run(~s|IO.puts("hi"); 1 + 2|)
  end

  test "every call to the outside is served in order, and its answer is what the script sees" do
    parent = self()

    on_call = fn name, args ->
      send(parent, {:called, name, args})

      case {name, args} do
        {"read", ["a.ex"]} -> %{"ok" => true, "content" => "defmodule A"}
        {"bash", ["ls"]} -> %{"exit_status" => 0, "output" => "a.ex\n"}
        {"now", []} -> 1_700_000_000
      end
    end

    code = """
    {:ok, out} = Script.bash("ls")
    files = String.split(out, "\\n", trim: true)
    texts = Enum.map(files, fn f -> {:ok, text} = Script.read(f); text end)
    {Script.now(), texts}
    """

    assert {:ok, {1_700_000_000, ["defmodule A"]}, ""} = run(code, on_call)
    assert_received {:called, "bash", ["ls"]}
    assert_received {:called, "read", ["a.ex"]}
    assert_received {:called, "now", []}
  end

  test "a restricted call, a runaway loop, a syntax error and an exception are failures, not crashes" do
    assert {:error, %{type: :restricted, message: message}} = run(~s|File.read!("x")|)
    assert message =~ "File.read!/1 is restricted"

    assert {:error, %{type: :reductions}} =
             Vm.run("Enum.reduce(1..10_000_000, 0, &+/2)", %{"reductions" => 100_000}, fn _, _ -> nil end)

    assert {:error, %{type: :parsing}} = run("1 +")
    assert {:error, %{type: :exception, message: message}} = run("1 / 0")
    assert message =~ "ArithmeticError"
  end

  test "the default limits let a script read a megabyte and pass over its lines, and still stop a runaway" do
    line = "Ubuntu 24.04, OTP 27.3\tUNKNOWN STEP\t2026-10-28T14:58:39Z lib/foo.ex:12: warning: unused variable\n"
    big = String.duplicate(line, div(1_000_000, byte_size(line)))
    on_call = fn "read", ["big.log"] -> %{"ok" => true, "content" => big} end

    pass = """
    {:ok, text} = Script.read("big.log")
    lines = String.split(text, "\\n")
    hits = for {l, i} <- Enum.with_index(lines), Regex.match?(~r/(FAIL|Error|error:|warning)/, l), do: i
    {length(lines), length(hits)}
    """

    assert {:ok, {lines, hits}, ""} = run(pass, on_call)
    assert lines > 10_000 and hits == lines - 1

    {us, outcome} = :timer.tc(fn -> run("f = fn f, n -> f.(f, n + 1) end; f.(f, 0)") end)
    assert {:error, %{type: :reductions}} = outcome
    assert us < 5_000_000

    {us, outcome} = :timer.tc(fn -> run("Enum.to_list(1..100_000_000)") end)
    assert {:error, %{type: :memory}} = outcome
    assert us < 5_000_000
  end

  test "watch_parent/3 waits while the daemon's OS process lives and acts once it is gone" do
    assert Vm.parent_alive?(System.pid())
    refute Vm.parent_alive?("4000000000")
    test = self()
    Vm.watch_parent("4000000000", 10, fn -> send(test, :gone) end)
    assert_received :gone
  end

  test "calling the API outside a running script raises, which is what the Api never does inside one" do
    assert_raise RuntimeError, "no script is running", fn -> Vm.call("read", ["x"]) end
  end

  describe "serve_stream/1: the protocol on a device" do
    defp serve(lines) do
      {:ok, device} = StringIO.open(Enum.map_join(lines, &Xeito.Scripts.Protocol.encode/1))
      :eof = Vm.serve_stream(device)
      {_in, out} = StringIO.contents(device)
      out |> String.split("\n", trim: true) |> Enum.map(&(&1 |> Xeito.Scripts.Protocol.decode() |> elem(1)))
    end

    test "ready, then each run answered with done or failed; a call is asked and its reply read" do
      assert [
               %{"t" => "ready"},
               %{"t" => "done", "id" => "s1", "value" => 3, "stdio" => ""},
               %{"t" => "call", "id" => "s2", "name" => "read", "args" => ["a"]},
               %{"t" => "done", "id" => "s2", "value" => "A"},
               %{"t" => "failed", "id" => "s3", "type" => "restricted"}
             ] =
               serve([
                 %{t: "run", id: "s1", code: "1 + 2"},
                 %{t: "run", id: "s2", code: ~s|{:ok, text} = Script.read("a"); text|},
                 %{t: "reply", id: "s2", value: %{"ok" => true, "content" => "A"}},
                 %{t: "run", id: "s3", code: ~s|File.read!("x")|}
               ])
    end

    test "a line that is not a run, and a call answered with something else, are failures the script sees" do
      assert [
               %{"t" => "ready"},
               %{"t" => "failed", "type" => "protocol"},
               %{"t" => "call"},
               %{"t" => "done", "value" => "the runner sent no reply"}
             ] =
               serve([
                 %{t: "hello"},
                 %{t: "run", id: "s1", code: ~s|{:error, reason} = Script.read("a"); reason|},
                 %{t: "nonsense", id: "s1"}
               ])
    end
  end
end
