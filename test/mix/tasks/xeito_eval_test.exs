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

  test "off-box tiers are skipped for a type whose policy forbids them, and only then" do
    Eval.run(~w(risk --deciders rules,remote --limit 2))
    assert output() =~ "risk: skipping remote (policy remote: :forbidden)"

    Eval.run(~w(triage --deciders rules --limit 2))
    refute output() =~ "skipping"
  end
end
