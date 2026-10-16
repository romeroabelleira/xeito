defmodule Xeito.Source.ModuleMapTest do
  use ExUnit.Case, async: true

  alias Xeito.Source.ModuleMap

  test "summary/1: the moduledoc's first sentence, on one line" do
    assert ModuleMap.summary("What a key may still\nspend. More detail.\n\nAnother paragraph.") ==
             "What a key may still spend."

    assert ModuleMap.summary("No full stop\n\nnext") == "No full stop"
    assert ModuleMap.summary(nil) == ""
    assert ModuleMap.summary("Ends with a path: `a.ex`.") == "Ends with a path: `a.ex`."
    assert String.length(ModuleMap.summary(String.duplicate("long ", 60))) <= 160
  end

  describe "entry/1" do
    test "a module's file, summary, and its public functions with their specs" do
      entry = ModuleMap.entry(Xeito.Allowance)

      assert entry.module == Xeito.Allowance
      assert entry.file == "lib/xeito/allowance.ex"
      assert entry.summary =~ "OpenRouter key"
      assert "worst_case(map() | nil, non_neg_integer(), non_neg_integer()) :: float()" in entry.functions
      # Hidden from docs (`@doc false`): not part of the interface.
      refute Enum.any?(entry.functions, &String.starts_with?(&1, "start_link"))
    end

    test "a function without a spec is listed by name and arity; a hidden one not at all" do
      docs = [
        {{:function, :a, 1}, 1, [], %{"en" => "A."}, %{}},
        {{:function, :b, 0}, 2, [], :hidden, %{}},
        {{:type, :t, 0}, 3, [], :none, %{}}
      ]

      assert ModuleMap.functions(docs, %{}) == ["a/1"]
      assert ModuleMap.functions(docs, %{{:a, 1} => ["a(x) :: x"]}) == ["a(x) :: x"]
    end
  end

  test "one_line/1: a spec broken over lines, on one" do
    assert ModuleMap.one_line("fit(\n  [message()],\n  keyword()\n) ::\n  {:ok, x}\n  | :error") ==
             "fit([message()], keyword()) :: {:ok, x} | :error"
  end

  describe "format/2" do
    setup do
      {:ok, entries: [ModuleMap.entry(Xeito.Allowance), ModuleMap.entry(Xeito.Budget)]}
    end

    test "modules only, one line each", %{entries: entries} do
      text = ModuleMap.format(entries, functions: false)
      assert text =~ ~r/^Xeito.Allowance  lib\/xeito\/allowance.ex  .+\nXeito.Budget  /
      refute text =~ "worst_case"
    end

    test "with functions, indented under their module", %{entries: entries} do
      assert ModuleMap.format(entries, functions: true) =~ "\n  worst_case(map() | nil"
    end
  end

  test "modules/1: the application's modules under a prefix, sorted" do
    assert [Xeito.Source, ModuleMap, Xeito.Source.ReadCost, Xeito.Source.RepoMap] ==
             ModuleMap.modules("Xeito.Source")

    assert Xeito.Allowance in ModuleMap.modules(nil)
    refute Enum.any?(ModuleMap.modules(nil), &match?(["Mix" | _], Module.split(&1)))
  end
end
