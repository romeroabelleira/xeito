defmodule Mix.Tasks.Xeito.Plan.CheckTest do
  # Uses Mix's shell.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Xeito.Plan.Check

  @moduletag :tmp_dir

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  defp repo!(dir, plan) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "lib/here.ex"), "defmodule Xeito.Here do\nend\n")
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "docs/plan.md"), plan)
    ["--plan", Path.join(dir, "docs/plan.md"), "--root", dir, "--today", "2026-11-03"]
  end

  test "a clean plan: no findings, exit 0", %{tmp_dir: dir} do
    args = repo!(dir, "# Plan\n\n## Milestones\n\n`Xeito.Here` (checked 2026-11-01: fine).\n")
    assert Check.run(args) == :ok
    assert_received {:mix_shell, :info, [text]}
    assert text =~ "no findings"
  end

  test "findings are printed by check with their line, and the task exits 1", %{tmp_dir: dir} do
    args = repo!(dir, "# Plan\n\n## Milestones\n\n`Xeito.Gone` ([x](#nowhere)) (checked 2026-01-01: old).\n")
    assert catch_exit(Check.run(args)) == {:shutdown, 1}
    assert_received {:mix_shell, :info, [text]}
    assert text =~ "Modules (1)\n  line 5: Xeito.Gone is not defined"
    assert text =~ "Links (1)\n  line 5: #nowhere"
    assert text =~ "Stale (1)\n  line 5: (checked 2026-01-01"
    assert text =~ ~r/\n3 findings$/
  end

  test "--help shows the documentation and checks nothing" do
    Check.run(["--help"])
    assert_received {:mix_shell, :info, ["mix xeito.plan.check\n\n" <> doc]}
    assert doc =~ "docs/implementation-plan.md"
  end
end
