defmodule Xeito.Machines.Chat.LimitsTest do
  use ExUnit.Case, async: true

  alias Xeito.Machines.Chat.Limits

  test "a turn has max_steps model turns, 25 by default, and 4 more once fixing" do
    assert Limits.limit(%{}) == 25
    assert Limits.limit(%{max_steps: 5}) == 5
    assert Limits.limit(%{max_steps: 5, fixing: true}) == 9
  end

  test "the limit is reached when the steps taken reach it; the last step is the one before" do
    refute Limits.at_limit?(%{max_steps: 5, steps: 4})
    assert Limits.at_limit?(%{max_steps: 5, steps: 5})
    assert Limits.at_limit?(%{max_steps: 5, steps: 8, fixing: false})
    refute Limits.at_limit?(%{max_steps: 5, steps: 8, fixing: true})

    refute Limits.last_step?(%{max_steps: 5, steps: 3})
    assert Limits.last_step?(%{max_steps: 5, steps: 4})
    refute Limits.last_step?(%{max_steps: 5})
  end

  test "at most two fixes, within four model turns past max_steps" do
    assert Limits.can_fix?(%{max_steps: 5, steps: 5})
    assert Limits.can_fix?(%{max_steps: 5, steps: 8, fixes: 1})
    refute Limits.can_fix?(%{max_steps: 5, steps: 9, fixes: 1})
    refute Limits.can_fix?(%{max_steps: 5, steps: 3, fixes: 2})
    assert Limits.fix_turns_left(%{max_steps: 5, steps: 6}) == 3
    assert Limits.fix_turns_left(%{max_steps: 5}) == 9
  end

  test "a stop puts a notice of why as the answer" do
    assert %{answer: "Stopped after 3 model turns (max_steps).", stopped: true, stop_reason: :limit} =
             Limits.stop(%{steps: 3})

    assert %{answer: "Stopped: the model kept making tool calls that could not run.", stop_reason: :invalid} =
             Limits.stop(%{steps: 3}, :invalid)
  end
end
