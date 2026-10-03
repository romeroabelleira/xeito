defmodule Xeito.MutateTest do
  # Hot-swaps a fixture module, so not async.
  use ExUnit.Case, async: false

  alias Xeito.Mutate

  defp described(source), do: source |> Mutate.mutants("m.ex") |> Enum.map(&{&1.line, &1.description})

  defp code(mutant), do: Macro.to_string(mutant.ast)

  describe "select/3: sources mutated only when they or their tests changed" do
    @config %{
      "a.ex" => ["a_test.exs"],
      "b.ex" => [tests: ["b_test.exs"], only_when_changed: true],
      "c.ex" => [tests: ["c_test.exs"], section: "s", only_when_changed: true]
    }

    test "an only_when_changed source is skipped when neither it nor its tests changed" do
      plan = Mutate.plan([], [], @config)
      assert [{"b.ex", nil, ["b_test.exs"]}, {"c.ex", "s", ["c_test.exs"]}] = Enum.drop(plan, 1)

      assert Mutate.select(plan, @config, ["a.ex", "other.ex"]) == {[{"a.ex", nil, ["a_test.exs"]}], ["b.ex", "c.ex"]}
      assert {[{"a.ex", _, _}, {"b.ex", _, _}], ["c.ex"]} = Mutate.select(plan, @config, ["b.ex"])
      assert {[{"a.ex", _, _}, {"c.ex", _, _}], ["b.ex"]} = Mutate.select(plan, @config, ["c_test.exs"])
    end

    test "when what changed is unknown, everything is mutated" do
      plan = Mutate.plan([], [], @config)
      assert Mutate.select(plan, @config, :all) == {plan, []}
    end
  end

  describe "mutants/2" do
    test "comparisons are negated, and ordering ones also moved across the boundary" do
      assert described("def f(a, b), do: a == b") == [{1, "== → !="}]
      assert described("def f(a, b), do: a !== b") == [{1, "!== → ==="}]
      assert described("def f(a), do: a > 0") == [{1, "> → <="}, {1, "> → >="}]
      assert described("def f(a), do: a <= 0") == [{1, "<= → >"}, {1, "<= → <"}]
    end

    test "boolean operators swap, negations drop, membership negates, if and unless swap" do
      assert described("def f(a, b), do: a and b") == [{1, "and → or"}]
      assert described("def f(a, b), do: a || b") == [{1, "|| → &&"}]
      assert described("def f(a), do: not a") == [{1, "not x → x"}]
      assert described("def f(a), do: !a") == [{1, "!x → x"}]
      assert described("def f(a), do: a in [1]") == [{1, "in → not in"}]
      assert described("def f(a), do: if(a, do: 1, else: 2)") == [{1, "if → unless"}]
    end

    test "arithmetic plus and minus swap; a unary minus is left alone" do
      assert described("def f(a), do: a + 1") == [{1, "+ → -"}]
      assert described("def f(a), do: -a") == []
    end

    test "each mutant changes exactly one place, in source order, with its line" do
      source = "def f(a, b) do\n  a == b and\n    a > 0\nend"
      mutants = Mutate.mutants(source, "m.ex")

      assert Enum.map(mutants, &{&1.line, &1.description}) ==
               [{2, "and → or"}, {2, "== → !="}, {3, "> → <="}, {3, "> → >="}]

      assert Enum.map(mutants, &code/1) == [
               "def f(a, b) do\n  a == b or a > 0\nend",
               "def f(a, b) do\n  a != b and a > 0\nend",
               "def f(a, b) do\n  a == b and a <= 0\nend",
               "def f(a, b) do\n  a == b and a >= 0\nend"
             ]
    end

    test "docs and types are not mutated; constants in attributes are" do
      assert described(~s{@doc "a" <> "b"\n@spec f(integer()) :: boolean()\ndef f(a), do: a == 1}) == [{3, "== → !="}]
      assert described("@limit 1 + 1") == [{1, "+ → -"}]
    end

    test "a clause of a multi-clause function is removed, one at a time" do
      source = "defmodule M do\n  def f(1), do: :a\n  def f(_), do: :b\n  defp g(x), do: x\nend"
      mutants = Mutate.mutants(source, "m.ex")
      assert Enum.map(mutants, &{&1.line, &1.description}) == [{2, "clause removed: f/1"}, {3, "clause removed: f/1"}]
      refute code(hd(mutants)) =~ ":a"
      assert code(hd(mutants)) =~ "def f(_)"
    end

    test "a clause of a case, cond or fn with several is removed" do
      assert described("case x do\n  1 -> :a\n  _ -> :b\nend") == [{2, "case clause removed"}, {3, "case clause removed"}]
      assert described("cond do\n  a -> 1\n  true -> 2\nend") == [{2, "cond clause removed"}, {3, "cond clause removed"}]
      assert described("fn\n  1 -> :a\n  _ -> :b\nend") == [{2, "fn clause removed"}, {3, "fn clause removed"}]
      assert described("case x do\n  _ -> :b\nend") == []
    end

    test "an element of a literal list is removed, one at a time" do
      assert described(~S|def f(s), do: String.contains?(s, [".env", ".ssh"])|) ==
               [{1, ~S|element removed: ".env"|}, {1, ~S|element removed: ".ssh"|}]

      assert described("def f, do: [~r/a/,\n  ~r/b/]") == [{1, "element removed: ~r/a/"}, {2, "element removed: ~r/b/"}]
      # Not when an element is computed, a keyword, a tail, or alone.
      assert described("def f(a), do: [a, 1]") == []
      assert described("def f, do: [a: 1, b: 2]") == []
      assert described(~S{def f(["a", "b" | rest]), do: rest}) == []
      assert described(~S|def f, do: ["a"]|) == []
    end

    test "a word of a ~w sigil is removed, one at a time" do
      mutants = Mutate.mutants("@safe ~w(ls cat pwd)", "m.ex")
      assert Enum.map(mutants, & &1.description) == ["word removed: ls", "word removed: cat", "word removed: pwd"]
      assert code(Enum.at(mutants, 1)) == "@safe ~w(ls pwd)"
    end

    test "only the given lines, when asked" do
      source = "def f(a), do: a == 1\ndef g(a), do: a == 2\n"
      assert source |> Mutate.mutants("m.ex", lines: [2..2]) |> Enum.map(& &1.line) == [2]
    end
  end

  describe "check/2: run the tests against each mutant, then restore the module" do
    @fixture """
    defmodule Xeito.MutateFixture do
      def positive?(x), do: x > 0
    end
    """

    setup do
      Code.compile_string(@fixture, "fixture.ex")

      on_exit(fn ->
        # Old code (from the swaps) first, then the current version.
        :code.purge(Xeito.MutateFixture)
        :code.delete(Xeito.MutateFixture)
        :code.purge(Xeito.MutateFixture)
      end)
    end

    # Called through a variable: the module exists only while a test runs.
    defp positive?(x), do: fixture().positive?(x)
    defp fixture, do: Module.concat(Xeito, "MutateFixture")

    # Tests that miss the boundary: 0 is never tried.
    defp weak_tests do
      if positive?(5) and not positive?(-5),
        do: %{failures: 0},
        else: %{failures: 1}
    end

    test "a mutant the tests notice is killed, one they miss survives" do
      results = Mutate.check(Mutate.mutants(@fixture, "fixture.ex"), &weak_tests/0)
      assert Enum.map(results, &{&1.description, &1.status}) == [{"> → <=", :killed}, {"> → >=", :survived}]
      assert positive?(1) and not positive?(0)
    end

    test "a mutant that does not compile is invalid, and the original stays loaded" do
      broken = %{
        line: 2,
        description: "broken",
        ast: quote(do: defmodule(Xeito.MutateFixture, do: def(f(x), do: y))),
        original: Code.string_to_quoted!(@fixture)
      }

      assert [%{status: :invalid}] = Mutate.check([broken], &weak_tests/0)
      assert positive?(1)
    end
  end

  test "summary/1 counts the results; the score is the share of valid mutants killed" do
    results = [%{status: :killed}, %{status: :killed}, %{status: :killed}, %{status: :survived}, %{status: :invalid}]
    assert Mutate.summary(results) == %{killed: 3, survived: 1, invalid: 1, score: 0.75}
    assert Mutate.summary([]).score == 1.0
  end

  test "format/2 shows where a survivor is, what changed, and the line" do
    lines = ["defmodule M do", "  def f(a), do: a > 0", "end"]

    assert Mutate.format(%{path: "lib/m.ex", line: 2, description: "> → >="}, lines) ==
             "lib/m.ex:2  > → >=  def f(a), do: a > 0"
  end

  test "modules/1: the modules a source file defines, nested ones by their full name" do
    source = "defmodule A.B do\n  defmodule C do\n  end\nend\ndefmodule D, do: nil\n"
    assert Mutate.modules(source) == ["A.B", "A.B.C", "D"]
  end

  describe "tests_for/2: the test files that use a module" do
    @files [
      {"test/a_test.exs", "alias Xeito.Decisions.Risk\nRisk.classify(x)"},
      {"test/b_test.exs", "alias Xeito.Decisions.{Intent, Risk}"},
      {"test/c_test.exs", "Xeito.Decisions.Risk.segments(x)"},
      {"test/d_test.exs", "alias Xeito.Decisions.Intent\n# Risky business"},
      {"test/e_test.exs", "alias Other.Risk"}
    ]

    test "by full name, or aliased from its namespace" do
      assert Mutate.tests_for(["Xeito.Decisions.Risk"], @files) == [
               "test/a_test.exs",
               "test/b_test.exs",
               "test/c_test.exs"
             ]
    end
  end

  describe "plan/3: which sources to mutate, against which tests" do
    @config %{
      "lib/a.ex" => ["test/a_test.exs"],
      "lib/b.ex" => ["test/b_test.exs", "test/a_test.exs"],
      "lib/c.ex" => [tests: ["test/c_test.exs"], section: "guards"]
    }

    test "without paths, each configured source with its section and its own tests" do
      assert Mutate.plan([], [], @config) == [
               {"lib/a.ex", nil, ["test/a_test.exs"]},
               {"lib/b.ex", nil, ["test/a_test.exs", "test/b_test.exs"]},
               {"lib/c.ex", "guards", ["test/c_test.exs"]}
             ]
    end

    test "given paths use the given tests, else their configured ones, else none (to be found)" do
      assert Mutate.plan(["lib/x.ex"], ["test/x_test.exs"], @config) == [{"lib/x.ex", nil, ["test/x_test.exs"]}]
      assert Mutate.plan(["lib/c.ex"], [], @config) == [{"lib/c.ex", "guards", ["test/c_test.exs"]}]
      assert Mutate.plan(["lib/x.ex"], [], @config) == [{"lib/x.ex", nil, []}]
    end
  end

  test "section_lines/2: from a section's marker comment to the next one, or the end" do
    source = "defmodule M do\n  # --- guards ----\n  def a, do: 1\n\n  # --- actions ---\n  def b, do: 2\nend\n"
    assert Mutate.section_lines(source, "guards") == 2..4
    assert Mutate.section_lines(source, "actions") == 5..8
    assert_raise ArgumentError, ~r/no section "nope"/, fn -> Mutate.section_lines(source, "nope") end
  end
end
