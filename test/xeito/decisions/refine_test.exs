defmodule Xeito.Decisions.RefineTest do
  use ExUnit.Case, async: true

  alias Xeito.Decider
  alias Xeito.Decision
  alias Xeito.Decision.Eval
  alias Xeito.Decisions.Refine

  test "a critique that finds nothing to change is done by rule, in English and Spanish wording" do
    for critique <- [
          "No changes needed.",
          "no change necessary",
          "Nothing to improve: it is two sentences.",
          "The draft stands.",
          "  The draft fully answers the request."
        ] do
      assert %{value: :done, actor: :rule} =
               Decider.decide(Refine, %{request: "r", draft: "d", critique: critique}, deciders: []),
             critique
    end
  end

  test "a critique that names a problem is not decided by rule" do
    assert %{value: :abstain} =
             Decider.decide(Refine, %{request: "r", draft: "d", critique: "The deadline is missing."}, deciders: [])
  end

  test "the type: two values, three inputs, the local tier, and labelled examples of both values" do
    type = Decision.type!(Refine)
    assert type.name == "refine"
    assert Decision.Type.values(type) == [:done, :revise]
    assert Enum.map(type.inputs, & &1.name) == [:request, :draft, :critique]

    examples = Eval.examples(Refine)
    assert length(examples) >= 12
    assert examples |> Enum.frequencies_by(& &1.label) |> Map.keys() |> Enum.sort() == [:done, :revise]
  end
end
