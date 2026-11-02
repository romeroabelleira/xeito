defmodule Xeito.Decisions.AdHocTest do
  use ExUnit.Case, async: true

  alias Xeito.Decider
  alias Xeito.Decision
  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Type
  alias Xeito.Decisions.AdHoc

  @choice %{"type" => "choice", "options" => ["low", "high"], "criteria" => "How urgent is the TODO?"}

  test "a choice question is a type whose values are its options; bool and score have theirs" do
    assert {:ok, %Type{module: AdHoc, name: "classify:urgency", version: "1", deciders: [:local_decision, :local]} = type} =
             AdHoc.type("urgency", @choice)

    assert Type.values(type) == [:low, :high]
    assert type.instructions == "How urgent is the TODO?"
    assert [%{name: :state, max_bytes: 8_000}] = type.inputs

    assert {:ok, type} = AdHoc.type("flaky", %{"type" => "bool", "criteria" => "Is the failure intermittent?"})
    assert Type.values(type) == [:yes, :no]

    assert {:ok, type} = AdHoc.type("quality", %{"type" => "score", "range" => [1, 3], "criteria" => "Code quality"})
    assert Type.values(type) == [:"1", :"2", :"3"]
  end

  test "a question that is not one of pi's shapes, or would make atoms at will, is refused with the reason" do
    assert {:error, "urgency: unknown question type \"rank\"" <> _} = AdHoc.type("urgency", %{"type" => "rank"})

    assert {:error, "urgency: a choice needs at least two options"} =
             AdHoc.type("urgency", %{@choice | "options" => ["x"]})

    assert {:error, "urgency: at most 16 options"} =
             AdHoc.type("urgency", %{@choice | "options" => Enum.map(1..17, &"o#{&1}")})

    assert {:error, "urgency: an option is a short lowercase word" <> _} =
             AdHoc.type("urgency", %{@choice | "options" => ["low", "Very High!"]})

    assert {:error, "urgency: criteria are required"} = AdHoc.type("urgency", Map.delete(@choice, "criteria"))

    assert {:error, "quality: a score's range is [min, max] with at most 10 values"} =
             AdHoc.type("quality", %{"type" => "score", "range" => [1, 20], "criteria" => "c"})

    assert {:error, "a question's name is a short lowercase word" <> _} = AdHoc.type("Bad Name", @choice)

    assert {:error, "urgency: a choice needs at least two options"} =
             AdHoc.type("urgency", Map.delete(@choice, "options"))

    assert {:error, "quality: a score's range is [min, max]" <> _} =
             AdHoc.type("quality", %{"type" => "score", "criteria" => "c"})

    assert {:error, "a question is a map with a type and criteria"} = AdHoc.type("urgency", "high")
    assert {:error, "urgency: criteria are required"} = AdHoc.type("urgency", %{@choice | "criteria" => ""})
  end

  test "the limits, exactly: 16 options, a range of 10 values with min at most max, both integers" do
    assert {:ok, _} = AdHoc.type("urgency", %{@choice | "options" => Enum.map(1..16, &"o#{&1}")})
    score = fn range -> AdHoc.type("quality", %{"type" => "score", "range" => range, "criteria" => "c"}) end
    assert {:ok, type} = score.([1, 10])
    assert length(Type.values(type)) == 10
    assert {:error, _} = score.([1, 11])
    assert {:ok, type} = score.([3, 3])
    assert Type.values(type) == [:"3"]
    assert {:error, _} = score.([3, 2])
    assert {:error, _} = score.(["1", 3])
    assert {:error, _} = score.([1, "3"])
    assert {:error, _} = score.([1.5, 3])
    assert {:error, _} = score.([1, 3.0])
  end

  test "an ad-hoc type is decided like a declared one: rules none, tiers in order, else abstain" do
    {:ok, type} = AdHoc.type("urgency", @choice)
    assert %Type{} = Decision.type!(type)
    assert Decision.describe(type) == "classify:urgency"
    assert Decision.describe(Xeito.Decisions.Triage) == "Xeito.Decisions.Triage"

    assert %Decision{value: :abstain, actor: :none} =
             Decider.decide(type, %{state: ~s({"todo": "fix later"})}, deciders: [])

    [%{role: "system", content: system}, %{role: "user", content: user}] = Prompt.messages(type, %{state: ~s({"a": 1})})
    assert system =~ "How urgent is the TODO?"
    assert system =~ "- low"
    assert user == ~s(state: {"a": 1})
  end
end
