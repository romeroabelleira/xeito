defmodule Xeito.Session.StepModeTest do
  use ExUnit.Case, async: true

  alias Xeito.Decisions.Risk
  alias Xeito.Session.StepMode

  test "breakpoint specs: a state, a decision type, a confidence; anything else is refused" do
    assert {:ok, {:state, :verifying}} = StepMode.parse_breakpoint("state:verifying")
    assert {:ok, {:decision, Risk}} = StepMode.parse_breakpoint("decision:risk")
    assert {:ok, {:confidence_below, 0.5}} = StepMode.parse_breakpoint("conf<0.5")

    for spec <- [
          "state:no_such_state_#{System.unique_integer([:positive])}",
          "decision:nope",
          "conf<high",
          "conf<0.5x",
          "sideways"
        ],
        do: assert(StepMode.parse_breakpoint(spec) == :error, spec)
  end

  test "breakpoint specs parse without creating atoms from input" do
    n = System.unique_integer([:positive])
    assert :error = StepMode.parse_breakpoint("state:no_such_state_#{n}")
    assert :error = StepMode.parse_breakpoint("decision:no_such_decision_#{n}")

    for name <- ["no_such_state_#{n}", "Elixir.Xeito.Decisions.NoSuchDecision#{n}"] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end
end
