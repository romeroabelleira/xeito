defmodule Xeito.SourceTest do
  use Xeito.Case, async: true

  alias Xeito.Effects.Local
  alias Xeito.Source
  alias Xeito.Tools

  @code """
  defmodule Shop.Cart do
    @moduledoc "A cart."

    def total(cart), do: Enum.sum(cart.items)

    def add(cart, item) when is_map(item) do
      %{cart | items: [item | cart.items]}
    end

    def add(cart, _other), do: cart

    defp helper do
      :ok
    end

    defmodule Line do
      def new(sku), do: %{sku: sku}
    end
  end
  """

  test "outline lists modules and definitions with line ranges, clauses grouped" do
    {:ok, text} = Source.outline("lib/cart.ex", @code)

    assert text =~ ~s(lib/cart.ex · 20 lines)

    assert text |> String.split("\n") |> tl() == [
             "defmodule Shop.Cart  1-19",
             "  def total/1  4-4",
             "  def add/2  6-10 (2 clauses)",
             "  defp helper/0  12-14",
             "  defmodule Shop.Cart.Line  16-18",
             "    def new/1  17-17"
           ]
  end

  test "symbol reads one definition by name, arity or module" do
    {:ok, add} = Source.symbol("lib/cart.ex", @code, "add/2")
    assert add =~ "lib/cart.ex lines 6-10:\n  def add(cart, item) when is_map(item) do"
    assert add =~ "def add(cart, _other), do: cart"

    assert {:ok, "lib/cart.ex lines 12-14:" <> _} = Source.symbol("lib/cart.ex", @code, "helper")

    assert {:ok, "lib/cart.ex lines 17-17:" <> _} =
             Source.symbol("lib/cart.ex", @code, "Line.new/1")

    assert {:ok, "lib/cart.ex lines 16-18:" <> _} = Source.symbol("lib/cart.ex", @code, "Line")
    assert {:error, "no definition" <> _} = Source.symbol("lib/cart.ex", @code, "remove")
  end

  test "tests are outlined under their describe blocks" do
    code = """
    defmodule CartTest do
      describe "add" do
        test "adds an item" do
          :ok
        end
      end
    end
    """

    {:ok, text} = Source.outline("test/cart_test.exs", code)
    assert text =~ ~s(  describe "add"  2-6\n    test "adds an item"  3-5)
  end

  test "syntax errors are described; other languages are not checked" do
    assert Source.syntax_error("a.ex", @code) == nil
    assert Source.syntax_error("a.ex", "def f do\n  x(\nend") =~ "line 2:"
    assert Source.syntax_error("a.json", "{\"a\": }") =~ "invalid JSON"
    assert Source.syntax_error("a.py", "def (:") == nil
    assert {:error, "outline and symbol support Elixir" <> _} = Source.outline("a.py", "")
  end

  test "the read tool outlines and reads symbols; edits report a file that no longer parses" do
    ws = Path.join(System.tmp_dir!(), "xeito-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(ws, "lib"))
    on_exit(fn -> File.rm_rf(ws) end)
    File.write!(Path.join(ws, "lib/cart.ex"), @code)
    ctx = %{cwd: ws}

    run = fn name, args ->
      {:ok, effect} = Tools.to_effect(%{name: name, arguments: args}, ctx)
      Local.run(effect, [])
    end

    assert %{ok: true, content: "lib/cart.ex · 20 lines" <> _} =
             run.("read", %{"path" => "lib/cart.ex", "outline" => true})

    assert %{ok: true, content: "lib/cart.ex lines 4-4:" <> _} =
             run.("read", %{"path" => "lib/cart.ex", "symbol" => "total"})

    broken =
      run.("edit", %{
        "path" => "lib/cart.ex",
        "old_text" => "    :ok\n",
        "new_text" => "    :ok(\n"
      })

    assert %{ok: true, syntax_error: "line " <> _} = broken
    assert Tools.result_text(broken) =~ "no longer parses"

    assert %{ok: true} =
             run.("edit", %{"path" => "lib/cart.ex", "old_text" => ":ok(", "new_text" => ":ok"})

    refute Map.has_key?(run.("read", %{"path" => "lib/cart.ex"}), :syntax_error)
  end

  describe "entries/2: definitions in less common shapes" do
    defp entries(source), do: elem(Source.entries("m.ex", source), 1)
    defp names(source), do: source |> entries() |> Enum.map(&{&1.kind, &1.name, &1.first, &1.last})

    test "a module whose body is a bare value, and a file without definitions" do
      assert [{:defmodule, "M", 1, 1}] = names("defmodule M, do: nil")
      assert Source.entries("m.ex", "1 + 1") == {:ok, []}
    end

    test "a definition without do-end or a following line ends at its deepest line" do
      source = "defmodule M,\n  do:\n    def(f(x),\n      do: x)\n"
      assert [{:defmodule, "M", 1, _}, {:def, "f/1", 3, 4}] = names(source)
    end

    test "definitions without parentheses, with guards, or with a computed name" do
      source = """
      defmodule M do
        def a, do: 1
        def b(x) when x > 0, do: x
        def unquote(:c)(x), do: x
      end
      """

      assert [{:defmodule, "M", 1, 5}, {:def, "a/0", 2, 2}, {:def, "b/1", 3, 3}] = names(source)
    end

    test "definitions in module-level blocks still count (not those in function bodies); only consecutive clauses are grouped" do
      source = """
      defmodule M do
        if true do
          def injected, do: 1
        end

        def outer, do: quote(do: def(hidden, do: 1))

        def f(1), do: :a
        def f(_), do: :b
        def g, do: :g
        def f(x, y), do: {x, y}
      end
      """

      assert [
               {:defmodule, "M", _, _},
               {:def, "injected/0", 3, 3},
               {:def, "outer/0", 6, 6},
               f,
               {:def, "g/0", 10, 10},
               {:def, "f/2", 11, 11}
             ] =
               names(source)

      assert f == {:def, "f/1", 8, 9}
      assert %{clauses: 2} = source |> entries() |> Enum.find(&(&1.name == "f/1"))
    end

    test "symbol/3 finds a module by its full name or its last part, a function with or without arity and module, and a test" do
      source = """
      defmodule Shop.Cart do
        def total(cart), do: cart
        test "adds an item", do: :ok
      end
      """

      for name <- [
            "Shop.Cart",
            "Cart",
            "total",
            "total/1",
            "Cart.total",
            "Shop.Cart.total/1",
            "adds an item",
            ~s("adds an item")
          ],
          do: assert({:ok, _} = Source.symbol("m.ex", source, name), name)

      for name <- ["Shop", "total/2", "Other.total", "adds"],
          do: assert({:error, _} = Source.symbol("m.ex", source, name), name)
    end
  end
end
