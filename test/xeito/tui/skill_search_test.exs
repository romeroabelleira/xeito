defmodule Xeito.Tui.SkillSearchTest do
  use ExUnit.Case, async: true

  alias Xeito.Tui.SkillSearch

  test "row/1: the skill, its description, and the tier and output it chose, if any" do
    assert SkillSearch.row(%{name: "greet", description: "Greet."}) == "  /skill:greet · Greet."

    assert SkillSearch.row(%{name: "judge", description: "Judge.", tier: "remote_frontier", output: {:json, "triage"}}) ==
             "  /skill:judge · Judge. · tier remote_frontier · json:triage"

    assert SkillSearch.row(%{name: "a", description: "D.", tier: nil, output: :text}) == "  /skill:a · D."
  end

  test "row/1: a long description is cut" do
    assert SkillSearch.row(%{name: "a", description: String.duplicate("x", 300)}) =~ ~r/x…$/
  end
end
