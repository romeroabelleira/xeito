# Live escalation check for P3: the delegation machine against the real tiers, with the large
# model unloaded and loaded, and each decision's logged state path.
#
#   mix run bench/scripts/p3_escalation_live.exs
#
# Tier endpoints come from the environment (config/runtime.exs). The script unloads the large
# model first (Ollama keep_alive: 0), so the first escalation that needs it has to swap.

alias Xeito.{Budget, Escalation, Log}
alias Xeito.Decisions.{Intent, Triage}

large = Xeito.Tiers.config(:large) || raise "large tier not configured"
unload = fn -> Req.post!(large[:url] <> "/api/generate", json: %{model: large[:model], keep_alive: 0}, receive_timeout: 60_000) end

log = Xeito.Log

cases = [
  {Triage, "triage, clear code bug", %{test: "PricingTest.test_total", output: "AssertionError: 8.0 != 108.0", diff_stat: "pricing.py | 2 +-"}},
  {Triage, "triage, ambiguous", %{test: "SyncTest.test_merge", output: "expected 3 items, got 2", diff_stat: ""}},
  {Intent, "intent, run tests", %{message: "Run the test suite, please."}}
]

run = fn type, label, input, opts ->
  parent = "p3-live-" <> Integer.to_string(System.unique_integer([:positive]))
  t0 = System.monotonic_time(:millisecond)
  d = Escalation.decide(type, input, [log: log, parent: parent, deciders: [:small, :large]] ++ opts)
  ms = System.monotonic_time(:millisecond) - t0

  [[child]] =
    Log.query(log, "SELECT ocel_source_id FROM object_object WHERE ocel_target_id = ?1 AND ocel_qualifier = 'part_of'", [parent])

  path = for {_, "state_entered", {:state_entered, s}} <- Log.read_run(log, child), do: s

  IO.puts("#{label}: #{d.value} by #{d.actor} (confidence #{inspect(d.confidence && Float.round(d.confidence, 3))}), #{ms} ms, swaps #{Budget.get(parent, :swaps)}")
  IO.puts("  path: " <> Enum.map_join(path, " → ", &to_string/1))
  small = Enum.find(d.evidence, &(&1[:tier] == :small)) || if(d.actor == :small, do: %{confidence: d.confidence})
  IO.puts("  small tier confidence: #{inspect(small && small[:confidence] && Float.round(small[:confidence], 3))}; cost: #{inspect(d.cost)}")
end

IO.puts("== large model unloaded before each case; strict placement (never accept a small answer instead of swapping)")

for {type, label, input} <- cases do
  unload.()
  run.(type, label, input, policy: [unloaded_accept: nil])
end

IO.puts("\n== large model now loaded")
for {type, label, input} <- cases, do: run.(type, label, input, [])

IO.puts("\n== large model unloaded before each case; placement-aware (accept a small answer ≥ 0.6 instead of swapping)")

for {type, label, input} <- cases do
  unload.()
  run.(type, label, input, policy: [unloaded_accept: 0.6])
end
