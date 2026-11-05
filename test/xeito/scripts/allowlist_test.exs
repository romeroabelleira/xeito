defmodule Xeito.Scripts.AllowlistTest do
  use ExUnit.Case, async: true

  alias Xeito.Scripts.Allowlist

  # As the VM does before a script: the allowed modules loaded, so their names exist for Dune's parser.
  defp eval(code) do
    Xeito.Scripts.Vm.preload()
    Dune.eval_string(code, allowlist: Allowlist, parse_timeout: 5_000, timeout: 5_000)
  end

  test "pure computation is allowed" do
    assert %Dune.Success{value: [2, 4]} = eval("Enum.map([1, 2], &(&1 * 2))")
    assert %Dune.Success{value: "A-B"} = eval(~s|Enum.join(["a", "b"], "-") \|> String.upcase()|)
    assert %Dune.Success{value: %{"n" => 3}} = eval(~s|%{"n" => String.length("abc")}|)
  end

  test "JSON decodes and encodes; the Erlang module under it and code evaluation stay refused" do
    assert %Dune.Success{value: %{"a" => [1, 2]}} = eval(~s|JSON.decode!(~s({"a": [1, 2]}))|)
    assert %Dune.Success{value: {:ok, [1]}} = eval(~s|JSON.decode("[1]")|)
    assert %Dune.Success{value: ~s({"n":3})} = eval(~s|JSON.encode!(%{"n" => 3})|)
    assert Allowlist.fun_status(JSON, :decode!, 1) == :allowed
    assert {:shimmed, Dune.Shims.JSON, :encode!} = Allowlist.fun_status(JSON, :encode!, 1)

    for code <- [~s|:json.decode("1")|, ~s|Code.string_to_quoted("1")|, ~s|Code.eval_string("1")|] do
      result = eval(code)
      assert %Dune.Failure{type: :restricted} = result, "#{code}: #{inspect(result)}"
    end
  end

  test "the file system, the environment, processes, the OS, code loading and the clock are refused" do
    for code <- [
          ~s|File.read!("mix.exs")|,
          ~s|System.get_env("HOME")|,
          ~s|System.cmd("ls", [])|,
          "Process.sleep(1)",
          "Process.list()",
          ":os.timestamp()",
          ~s|Code.eval_string("1")|,
          "DateTime.utc_now()",
          "Date.utc_today()",
          ":erlang.monotonic_time()",
          ":erlang.unique_integer()",
          ":rand.uniform()",
          "spawn(fn -> :ok end)"
        ] do
      result = eval(code)
      assert %Dune.Failure{type: :restricted} = result, "#{code}: #{inspect(result)}"
    end
  end

  test "the fingerprint names this allow-list and Dune's version: short, stable, and logged with each script" do
    assert Allowlist.fingerprint() == Allowlist.fingerprint()
    assert Allowlist.fingerprint() =~ ~r/^[0-9a-f]{8,16}$/
  end

  test "the script API is allowed by name, under its short name too" do
    assert Allowlist.fun_status(Xeito.Scripts.Api, :read, 1) == :allowed
    assert Allowlist.fun_status(Script, :read, 1) == :allowed
    assert Allowlist.fun_status(File, :read, 1) == :restricted
    assert Allowlist.fun_status(Enum, :map, 2) == :allowed
  end
end
