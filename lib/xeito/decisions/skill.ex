defmodule Xeito.Decisions.Skill do
  @moduledoc """
  Which of the user's skills, if any, a chat request needs (P4e).

  The session shortlists up to three of the user's skills by keyword (`Xeito.Skills.rank/3`);
  this decision picks one of them, or none, at the start of a chat turn
  (`Xeito.Machines.Chat`, state `choosing_skill`). A decision type has a fixed set of values while
  skills differ per directory, so the values are positions in the shortlist: each candidate
  input is `"<name>: <description>"`.

  Rules decide first: no candidates is `none`, and a request that names a candidate picks it.
  The model decides the rest.
  """

  use Xeito.Decision, version: "1"

  instructions """
  A skill is a set of instructions for one kind of task. Does this request ask for the kind of \
  task one of the listed skills is for? Choose that skill, or none.\
  """

  input :request, max_bytes: 2_000
  input :first, max_bytes: 600, required: false
  input :second, max_bytes: 600, required: false
  input :third, max_bytes: 600, required: false

  value :first, "the first skill listed fits the request"
  value :second, "the second skill listed fits the request"
  value :third, "the third skill listed fits the request"
  value :none, "no listed skill fits: the request is not the kind of task any of them is for"

  rule :no_candidates?, then: :none
  rule :names_first?, then: :first
  rule :names_second?, then: :second
  rule :names_third?, then: :third

  deciders [:local]
  min_confidence 0.6

  @doc false
  def no_candidates?(input), do: blank?(input[:first])

  @doc false
  def names_first?(input), do: names?(input, :first)
  @doc false
  def names_second?(input), do: names?(input, :second)
  @doc false
  def names_third?(input), do: names?(input, :third)

  # The request names the candidate: "code-review" or "code review", as whole words.
  defp names?(input, key) do
    case input[key] do
      nil ->
        false

      candidate ->
        name = candidate |> String.split(":", parts: 2) |> hd() |> String.trim()
        spelled = name |> Regex.escape() |> String.replace(~r/\\?-/, "[- ]")
        name != "" and Regex.match?(~r/\b#{spelled}\b/i, input.request)
    end
  end

  defp blank?(text), do: text in [nil, ""]
end
