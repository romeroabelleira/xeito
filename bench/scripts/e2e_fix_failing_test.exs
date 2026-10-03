# End-to-end check for P2: fix_failing_test on a seeded failing repository, with Triage decided
# by the CPU tiers and logged with its confidence.
#
#   mix run bench/scripts/e2e_fix_failing_test.exs
#
# Tier endpoints come from the environment (config/runtime.exs). The "planning" and "editing"
# states are driven by this script (as a human would), because the edit tiers arrive later.

alias Xeito.{Log, Run, RunSupervisor}

ws = Path.join(System.tmp_dir!(), "xeito-e2e-#{System.unique_integer([:positive])}")
File.mkdir_p!(ws)

File.write!(Path.join(ws, "pricing.py"), """
def total(prices, tax):
    return sum(prices) * tax
""")

File.write!(Path.join(ws, "test_pricing.py"), """
import unittest
from pricing import total

class PricingTest(unittest.TestCase):
    def test_total_includes_tax(self):
        self.assertAlmostEqual(total([100.0], 0.08), 108.0)

if __name__ == "__main__":
    unittest.main()
""")

input = %{
  cwd: ws,
  test_cmd: "python3 -m unittest -q test_pricing 2>&1",
  test_name: "PricingTest.test_total_includes_tax",
  diff_stat: "pricing.py | 2 +-"
}

deciders = System.get_env("XEITO_E2E_DECIDERS", "local") |> String.split(",") |> Enum.map(&String.to_existing_atom/1)
runner = {Xeito.Effects.Local, decider: [deciders: deciders]}
{:ok, id} = RunSupervisor.start_run(Xeito.Machines.FixFailingTest, input, runner: runner)

wait = fn wait, deadline ->
  leaf = Run.whereis(id) && Run.snapshot(id).leaf

  cond do
    leaf == nil -> :finished
    leaf in [:planning, :ask_human] -> leaf
    System.monotonic_time(:millisecond) > deadline -> {:timeout, leaf}
    true -> Process.sleep(50) && wait.(wait, deadline)
  end
end

case wait.(wait, System.monotonic_time(:millisecond) + 60_000) do
  :planning ->
    Run.send_event(id, :planned, %{plan: "multiply by (1 + tax)"})
    File.write!(Path.join(ws, "pricing.py"), "def total(prices, tax):\n    return sum(prices) * (1 + tax)\n")
    Run.send_event(id, :edited, %{files: ["pricing.py"]})

  :ask_human ->
    IO.puts("triage asked a human; answering and applying the fix")
    Run.send_event(id, :answered)
    wait.(wait, System.monotonic_time(:millisecond) + 5_000)
    Run.send_event(id, :planned)
    File.write!(Path.join(ws, "pricing.py"), "def total(prices, tax):\n    return sum(prices) * (1 + tax)\n")
    Run.send_event(id, :edited)

  other ->
    IO.puts("unexpected: #{inspect(other)}")
end

Process.sleep(2_000)
entries = Log.read_run(Xeito.Log, id)

for {_, "decision_made", {:decision_made, _, d}} <- entries do
  IO.puts(
    "decision: #{inspect(d.type)} = #{d.value} (confidence #{Float.round(d.confidence || 0.0, 3)}, " <>
      "actor #{d.actor}, model #{d.model}, #{d.latency_ms} ms)"
  )

  IO.puts("  probabilities: #{inspect(Map.new(d.probabilities, fn {k, v} -> {k, Float.round(v, 3)} end))}")
  for e <- d.evidence, do: IO.puts("  evidence: #{inspect(e)}")
end

path = for({_, "transition", {:transition, from, to, _, actor}} <- entries, do: "#{from}→#{to} (#{actor})")
IO.puts("path: " <> Enum.join(path, ", "))
IO.puts("result: #{inspect(Run.result(Xeito.Log, id))}")
File.rm_rf!(ws)
