defmodule Xeito.Decisions.Refine do
  @moduledoc "The decision whether a draft answer stands or a critique of it calls for a revision (`Xeito.Machines.SelfRefine`)."

  use Xeito.Decision, version: "1", name: "refine"

  instructions "Given the request, a draft answer and a critique of the draft, should the draft be revised?"

  input :request, max_bytes: 1_000
  input :draft, max_bytes: 3_000, keep: :tail
  input :critique, max_bytes: 2_000

  value :done, "the critique finds nothing that would change the answer: the draft stands as it is"
  value :revise, "the critique names something wrong, missing, unclear or too long that a revision would fix"

  rule :no_changes?, then: :done

  # Smaller tiers are left out until they pass the zero-shot gate for this type.
  deciders [:local]
  min_confidence 0.8

  @doc false
  def no_changes?(%{critique: critique}) do
    Regex.match?(
      ~r/^\W*(no changes? (are |is )?(needed|necessary|required)|nothing to (change|improve|add|fix)|the draft (stands|is fine|fully answers|needs no change))/i,
      String.trim(critique)
    )
  end
end
