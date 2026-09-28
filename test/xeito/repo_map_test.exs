defmodule Xeito.RepoMapTest do
  use ExUnit.Case, async: true

  alias Xeito.Source.RepoMap

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-map-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(ws, "lib/shop"))
    File.mkdir_p!(Path.join(ws, "deps/term_ui"))
    on_exit(fn -> File.rm_rf(ws) end)
    File.write!(Path.join(ws, "mix.exs"), "defmodule Shop.MixProject do\nend\n")

    File.write!(Path.join(ws, "lib/shop/cart.ex"), """
    defmodule Shop.Cart do
      @moduledoc \"\"\"
      A shopping cart.
      \"\"\"

      def total(cart), do: 0
      def add(cart, item), do: [item | cart]
      defp helper, do: :ok
    end
    """)

    %{ws: ws}
  end

  test "names the project kind, modules with docs and public functions, and dependencies", %{
    ws: ws
  } do
    map = RepoMap.build(ws)
    assert map =~ "Elixir (Mix) project. Top level: deps/ lib/"
    assert map =~ "  Shop.Cart  lib/shop/cart.ex — A shopping cart."
    assert map =~ "    total/1 add/2"
    refute map =~ "helper"
    assert map =~ "Dependencies (sources in deps/<name>/lib, read-only): term_ui"
  end

  test "shrinks to fit: functions first, then docs, then modules", %{ws: ws} do
    for i <- 1..40 do
      File.write!(Path.join(ws, "lib/shop/m#{i}.ex"), """
      defmodule Shop.M#{i} do
        @moduledoc "Module number #{i}, with a fairly long description line to take up space."
        def f#{i}(x), do: x
      end
      """)
    end

    full = RepoMap.build(ws, 100_000)
    assert full =~ "f7/1" and full =~ "Module number 7"

    names = RepoMap.build(ws, 3_000)
    refute names =~ "f7/1" or names =~ "Module number"
    assert names =~ "  Shop.M7  lib/shop/m7.ex"

    cut = RepoMap.build(ws, 800)
    assert String.length(cut) <= 800
    assert cut =~ ~r/… \d+ more modules/
  end

  test "an empty directory has no map" do
    dir = Path.join(System.tmp_dir!(), "xeito-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    assert RepoMap.build(dir) == nil
  end
end
