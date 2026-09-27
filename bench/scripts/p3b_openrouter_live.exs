# Live escalation check for P3b: the OpenRouter tier inside the delegation machine.
#
#   mix run bench/scripts/p3b_openrouter_live.exs
#
# Tier endpoints come from the environment (config/runtime.exs). The inputs are synthetic.
# The large model is unloaded first, so the ladder small → openrouter → large shows whether a
# hosted answer spares the local swap. Spends a fraction of a cent.

alias Xeito.{Budget, Escalation, Log}
alias Xeito.Decisions.{Intent, Risk, Triage}

Xeito.Tiers.config(:openrouter) || raise "openrouter tier not configured"
large = Xeito.Tiers.config(:large) || raise "large tier not configured"

unload = fn ->
  Req.post!(large[:url] <> "/api/generate",
    json: %{model: large[:model], keep_alive: 0},
    receive_timeout: 60_000
  )
end

log = Xeito.Log

cases = [
  {Triage, "triage, clear code bug",
   %{test: "PricingTest.test_total", output: "AssertionError: 8.0 != 108.0", diff_stat: "pricing.py | 2 +-"}},
  {Triage, "triage, ambiguous",
   %{test: "SyncTest.test_merge", output: "expected 3 items, got 2", diff_stat: ""}},
  {Intent, "intent, run tests", %{message: "Run the test suite, please."}}
]

run = fn type, label, input, opts ->
  parent = "p3b-live-" <> Integer.to_string(System.unique_integer([:positive]))
  t0 = System.monotonic_time(:millisecond)

  d =
    Escalation.decide(
      type,
      input,
      [log: log, parent: parent, deciders: [:small, :openrouter, :large]] ++ opts
    )

  ms = System.monotonic_time(:millisecond) - t0

  [[child]] =
    Log.query(
      log,
      "SELECT ocel_source_id FROM object_object WHERE ocel_target_id = ?1 AND ocel_qualifier = 'part_of'",
      [parent]
    )

  path = for {_, "state_entered", {:state_entered, s}} <- Log.read_run(log, child), do: s
  conf = d.confidence && Float.round(d.confidence, 3)

  IO.puts("#{label}: #{d.value} by #{d.actor} (confidence #{inspect(conf)}), #{ms} ms")
  IO.puts("  model: #{d.model}")
  IO.puts("  path: " <> Enum.map_join(path, " → ", &to_string/1))
  IO.puts("  cost: #{inspect(d.cost)}; run spend charged: $#{Budget.get(parent, :usd)}")
end

IO.puts("== default policy (local-only inputs): openrouter must not appear in the path")
for {type, label, input} <- cases, do: run.(type, label, input, [])

IO.puts("\n== public inputs, off-box allowed, large model unloaded before each case")

for {type, label, input} <- cases do
  unload.()
  run.(type, label, input, policy: [remote: :allowed, locality: :public, unloaded_accept: nil])
end

IO.puts("\n== Risk with off-box requested: never leaves the box")

run.(Risk, "risk, unknown command", %{command: "some-unknown-tool --flag"},
  policy: [remote: :allowed, locality: :public]
)
