defmodule Xeito.EffectsTest do
  use ExUnit.Case, async: true

  alias Xeito.Effect
  alias Xeito.Effects

  test "error_result/2: an effect that raised gets a result of its kind's shape, reporting the error" do
    assert Effects.error_result(Effect.bash("x"), "boom") == %{exit_status: -1, output: "boom"}

    assert Effects.error_result(%Effect{kind: :decide, args: %{}, reply: nil}, "boom") == %{
             value: :abstain,
             error: "boom"
           }

    assert Effects.error_result(Effect.read("a"), "boom") == %{ok: false, error: "boom"}
  end
end
