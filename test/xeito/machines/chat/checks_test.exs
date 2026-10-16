defmodule Xeito.Machines.Chat.ChecksTest do
  use ExUnit.Case, async: true

  alias Xeito.Machines.Chat.Checks

  test "checks run only when the input names a command" do
    assert Checks.verify?(%{verify: "mix test"})
    refute Checks.verify?(%{verify: ""})
    refute Checks.verify?(%{verify: nil})
    refute Checks.verify?(%{})
  end

  test "the fix prompt gives the exit status, the turns left and the output's tail" do
    ctx = %{verify: "mix test", max_steps: 5, steps: 6}
    long = String.duplicate("x", 5_000) <> "the end"

    assert %{role: "user", content: text} = Checks.fix_prompt(ctx, %{exit_status: 2, output: long})
    assert text =~ "The project's checks (`mix test`) fail after your edits, exit status 2."
    assert text =~ "You have 3 more model turns for this."
    assert text =~ "\n…" <> String.duplicate("x", 3_993) <> "the end\n"

    assert Checks.fix_prompt(ctx, %{exit_status: 1, output: "short"}).content =~ "Output (tail):\nshort\n"
    exact = String.duplicate("y", 4_000)
    assert Checks.fix_prompt(ctx, %{exit_status: 1, output: exact}).content =~ "Output (tail):\n" <> exact <> "\n"
    assert Checks.fix_prompt(ctx, %{exit_status: 1, output: "raw", shaped: "shaped"}).content =~ "(tail):\nshaped\n"
  end

  test "the outcome is recorded; a failure is noted in the answer" do
    passed = Checks.record(%{verify: "mix test", answer: "Done."}, %{exit_status: 0})
    assert passed.checks == %{cmd: "mix test", exit_status: 0, passed: true}
    assert passed.answer == "Done."

    failed = Checks.record(%{verify: "mix test", answer: "Done."}, %{exit_status: 1})
    assert failed.checks.passed == false
    assert failed.answer == "Done.\n\n⚠ The checks still fail after this turn's edits (`mix test`, exit 1)."
  end
end
