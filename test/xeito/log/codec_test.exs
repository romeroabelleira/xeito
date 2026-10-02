defmodule Xeito.Log.CodecTest do
  use ExUnit.Case, async: true

  alias Xeito.Log.Codec

  defmodule Point, do: defstruct([:x, :y])

  test "jsonable/1 turns any term into JSON-encodable data" do
    assert Codec.jsonable(%{:a => [1, :b, {2, "c"}], "d" => nil, 3 => true}) == %{
             "a" => [1, "b", [2, "c"]],
             "d" => nil,
             "3" => true
           }

    assert Codec.jsonable(%Point{x: 1, y: 2.5}) == %{"x" => 1, "y" => 2.5}
    assert Codec.jsonable(<<255, 0>>) == "<<255, 0>>"
    assert Codec.jsonable(self()) == inspect(self())
    assert Codec.jsonable(%{{1, 2} => :pair}) == %{"{1, 2}" => "pair"}
  end
end
