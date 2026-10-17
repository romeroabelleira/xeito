defmodule Mix.Tasks.Xeito.EvalTest do
  # Mix's shell is global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Xeito.Eval

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    dir = Path.join(System.tmp_dir!(), "xeito-evaltask-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp output(acc \\ "") do
    receive do
      {:mix_shell, :info, [line]} -> output(acc <> line <> "\n")
    after
      0 -> acc
    end
  end

  test "evaluates deciders without models, writes the report and one tier's predictions", %{dir: dir} do
    Eval.run(~w(risk --deciders rules,baseline --limit 6 --out #{dir} --predictions rules))
    out = output()

    assert out =~ ~r/risk v\d+: 6 examples/
    assert out =~ ~r/^  baseline\s+\d\.\d{3}/m
    assert out =~ ~r/^  rules\s+\d\.\d{3}\s+\d\.\d{3}\s+\d\.\d{3}\s+\d\.\d{3}\s+\d\.\d{3}\s+-\s+-/m
    assert %{"type" => "risk", "examples" => 6} = dir |> Path.join("risk.json") |> File.read!() |> JSON.decode!()
    assert [_ | _] = dir |> Path.join("risk.rules.jsonl") |> File.read!() |> String.split("\n", trim: true)
  end

  test "risk: errors weighed by severity, and the severity gate against an earlier report", %{dir: dir} do
    Eval.run(~w(risk --deciders rules --out #{dir}))
    out = output()
    assert out =~ ~r/^  severity rules\s+false-safe \d+ \(\d\.\d{3}\)\s+review burden \d\.\d{3}/m
    assert out =~ ~r/^  severity gate rules: (PASS|fail) \(false-safe \d+, cost \d\.\d{3} vs before -\)$/m

    report = dir |> Path.join("risk.json") |> File.read!() |> JSON.decode!()
    assert %{"severity" => %{"rules" => %{"false_safe" => _, "expected_cost" => cost}}} = report

    # A rise in expected cost against the earlier report fails the gate.
    earlier = Path.join(dir, "earlier.json")
    File.write!(earlier, JSON.encode!(put_in(report, ["severity", "rules", "expected_cost"], cost - 1)))
    Eval.run(~w(risk --deciders rules --against #{earlier}))
    assert output() =~ ~r/^  severity gate rules: fail \(false-safe \d+, cost \d\.\d{3} vs before -?\d\.\d{3}\)$/m

    Eval.run(~w(triage --deciders rules --limit 2))
    refute output() =~ "severity"
  end

  test "off-box tiers are skipped for a type whose policy forbids them, and only then" do
    Eval.run(~w(risk --deciders rules,remote,remote_frontier --limit 2))
    assert output() =~ "risk: skipping remote, remote_frontier (policy remote: :forbidden)"

    Eval.run(~w(triage --deciders rules --limit 2))
    refute output() =~ "skipping"
  end
end
