defmodule Xeito.DeciderTest do
  use ExUnit.Case, async: true

  alias Xeito.Decider
  alias Xeito.Decisions.Intent

  test "decide/3: intent rules answer small talk and 'run the tests' without a model" do
    for msg <- ["hi", "Thanks!", "ok", "good morning"] do
      assert %{value: :other, actor: :rule} =
               Decider.decide(Intent, %{message: msg}, deciders: [])
    end

    assert %{value: :run, actor: :rule} =
             Decider.decide(Intent, %{message: "run the tests"}, deciders: [])

    assert %{value: :abstain} =
             Decider.decide(Intent, %{message: "hi, why is the build slow?"}, deciders: [])
  end
end
