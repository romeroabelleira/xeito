defmodule Xeito.Scripts.ProtocolTest do
  use ExUnit.Case, async: true

  alias Xeito.Scripts.Protocol

  test "a message is one JSON line with string keys, and decodes back" do
    line = Protocol.encode(%{t: "call", id: 3, name: "read", args: ["a.ex"]})
    assert String.ends_with?(line, "\n")
    assert Protocol.decode(line) == {:ok, %{"t" => "call", "id" => 3, "name" => "read", "args" => ["a.ex"]}}
  end

  test "a line that is not a message, or has no type, is an error with the line" do
    assert Protocol.decode("{oops\n") == {:error, "{oops\n"}
    assert Protocol.decode(~s({"id": 1})) == {:error, ~s({"id": 1})}
  end

  test "values JSON cannot carry are inspected; atoms and keys become strings; structs are inspected whole" do
    assert Protocol.jsonable(%{ok: true, pair: {1, 2}, who: :me, list: [1, nil]}) ==
             %{"ok" => true, "pair" => "{1, 2}", "who" => "me", "list" => [1, nil]}

    assert Protocol.jsonable(%{{1, 2} => 3}) == %{"{1, 2}" => 3}
    assert Protocol.jsonable(~D[2026-10-31]) == "~D[2026-10-31]"
    assert Protocol.jsonable(fn -> :ok end) =~ "#Function"
  end
end
