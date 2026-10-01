defmodule Xeito.CrapTest do
  use ExUnit.Case, async: true

  alias Xeito.Crap

  describe "score/2: complexity² × (1 − coverage)³ + complexity" do
    test "is the complexity when fully covered" do
      assert Crap.score(1, 1.0) == 1.0
      assert Crap.score(31, 1.0) == 31.0
    end

    test "grows with the square of the complexity as coverage falls" do
      assert Crap.score(5, 0.0) == 30.0
      assert Crap.score(10, 0.5) == 22.5
    end
  end

  describe "functions/2: cyclomatic complexity per function" do
    defp complexity(body) do
      [f] = Crap.functions("m.ex", "defmodule M do\n" <> body <> "\nend\n")
      f.complexity
    end

    test "a function without decisions is 1" do
      assert complexity("def f(x), do: x") == 1
    end

    test "if, unless and boolean operators add one each" do
      assert complexity("def f(x), do: if(x, do: 1, else: 2)") == 2
      assert complexity("def f(x), do: unless(x, do: 1)") == 2
      assert complexity("def f(x), do: (x && g(x)) || h()") == 3
      assert complexity("def f(x) when x > 0 and x < 9, do: x") == 2
    end

    test "case, cond and anonymous functions add one per clause after the first" do
      assert complexity("def f(x) do\n  case x do\n    1 -> :a\n    2 -> :b\n    _ -> :c\n  end\nend") == 3
      assert complexity("def f(x) do\n  cond do\n    x > 1 -> :a\n    true -> :b\n  end\nend") == 2
      assert complexity("def f(xs), do: Enum.map(xs, fn\n  1 -> :a\n  _ -> :b\nend)") == 2
    end

    test "with adds one per pattern that can fail, and per else clause after the first" do
      assert complexity(
               "def f(x) do\n  with {:ok, a} <- g(x),\n       {:ok, b} <- h(a) do\n    b\n  else\n    {:error, e} -> e\n    _ -> nil\n  end\nend"
             ) == 4
    end

    test "each further clause of a function adds one" do
      assert complexity("def f(1), do: :a\ndef f(_), do: :b") == 2
    end

    test "functions are named name/arity with their module and line range" do
      source = "defmodule M do\n  def a, do: 1\n\n  defp b(x) do\n    x\n  end\nend\n"

      assert [
               %{module: "M", name: "a/0", first: 2, last: 2, complexity: 1},
               %{module: "M", name: "b/1", first: 4, last: 6, complexity: 1}
             ] = Crap.functions("m.ex", source)
    end
  end

  describe "coverage/3: share of a function's executable lines that ran" do
    @lines [{1, 0}, {2, 3}, {3, 1}, {4, 0}]

    test "counts the executable lines in the range that were called" do
      assert Crap.coverage(@lines, 2, 3) == 1.0
      assert Crap.coverage(@lines, 1, 4) == 0.5
    end

    test "a range without executable lines counts as covered" do
      assert Crap.coverage(@lines, 5, 9) == 1.0
    end
  end

  describe "offenders/2" do
    test "the functions over the maximum, worst first" do
      scored = [%{name: "a/0", crap: 12.0}, %{name: "b/0", crap: 31.0}, %{name: "c/0", crap: 45.5}]
      assert Enum.map(Crap.offenders(scored, 30), & &1.name) == ["c/0", "b/0"]
    end
  end

  describe "gate/3: the maximum, with a baseline that may only shrink" do
    defp f(name, crap), do: %{module: "M", name: name, crap: crap}

    test "passes when every function is at or under the maximum" do
      assert Crap.gate([f("a/0", 12.0), f("b/0", 30.0)], 30, %{}) == :ok
    end

    test "fails for a function over the maximum that is not in the baseline" do
      assert {:error, [over: [%{name: "b/0"}]]} = Crap.gate([f("a/0", 1.0), f("b/0", 31.0)], 30, %{})
    end

    test "a baselined function may stay over the maximum, but not get worse" do
      assert Crap.gate([f("b/0", 120.0)], 30, %{"M.b/0" => 120.0}) == :ok
      assert {:error, [worse: [%{name: "b/0"}]]} = Crap.gate([f("b/0", 121.0)], 30, %{"M.b/0" => 120.0})
    end

    test "a baseline entry no longer needed fails until it is removed" do
      assert {:error, [stale: ["M.b/0"]]} = Crap.gate([f("b/0", 20.0)], 30, %{"M.b/0" => 120.0})
      assert {:error, [stale: ["M.gone/0"]]} = Crap.gate([], 30, %{"M.gone/0" => 50.0})
    end
  end
end
