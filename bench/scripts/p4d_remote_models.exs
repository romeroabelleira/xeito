# P4d step 3: the frontier models on the decision eval sets, through the Claude API.
#
#   . ~/.config/xeito/tiers.env && mix run bench/scripts/p4d_remote_models.exs [OUT_DIR] [MODEL ...]
#
# Every type whose policy allows off-box tiers runs its labelled examples against `local` and
# against `remote_frontier` with each MODEL (default: claude-opus-5-5 and claude-sonnet-5-5),
# each tier called directly, outside the escalation ladder, as `mix xeito.eval` does. Per decider:
# the eval's metrics (accuracy, macro F1, ECE, latency), the errors, and for the remote models the
# cost the backend computed from the API's usage at list prices. One JSON report per type goes to
# OUT_DIR (default bench/decisions/p4d). P4D_LIMIT=N takes the first N examples of each type.
# Spends real money: about 300 decisions per model.

alias Xeito.Decider
alias Xeito.Decision
alias Xeito.Decision.Eval
alias Xeito.Decision.Type

default_models = ["claude-opus-5-5", "claude-sonnet-5-5"]

{out, models} =
  case System.argv() do
    [] -> {"bench/decisions/p4d", default_models}
    [out] -> {out, default_models}
    [out | models] -> {out, models}
  end

limit = System.get_env("P4D_LIMIT") && String.to_integer(System.get_env("P4D_LIMIT"))
Xeito.Tiers.config(:remote_frontier) || raise "remote_frontier is not configured"
Xeito.Tiers.config(:local) || raise "local is not configured"
File.mkdir_p!(out)
workspaces = Path.join(System.tmp_dir!(), "xeito-p4d-#{System.unique_integer([:positive])}")

run = fn type, tier, overrides, examples ->
  Enum.map(examples, fn ex ->
    normalized = Type.normalize_input(type, ex.input)
    started = System.monotonic_time(:millisecond)

    outcome =
      case Decider.run_tier(type, tier, normalized, overrides) do
        {:ok, r} ->
          Map.put(
            %{predicted: r.value, confidence: r.confidence, probabilities: r.probabilities, model: r.model},
            :cost,
            r[:cost]
          )

        {:error, reason} ->
          %{predicted: :abstain, confidence: nil, probabilities: %{}, error: inspect(reason)}
      end

    latency = System.monotonic_time(:millisecond) - started
    Map.merge(%{label: ex.label, lang: ex.lang, latency_ms: latency, dangerous: ex.dangerous}, outcome)
  end)
end

spend = fn results ->
  costs = results |> Enum.map(& &1[:cost]) |> Enum.reject(&is_nil/1)
  sum = fn key -> costs |> Enum.map(&(&1[key] || 0)) |> Enum.sum() end
  n = length(results)

  %{
    usd: Float.round(sum.(:usd) * 1.0, 5),
    usd_per_decision: if(n > 0, do: Float.round(sum.(:usd) / n, 6)),
    tokens_in: sum.(:tokens_in),
    tokens_out: sum.(:tokens_out),
    errors: Enum.count(results, &Map.has_key?(&1, :error)),
    error_sample: results |> Enum.find_value(& &1[:error]) |> then(&(&1 && String.slice(&1, 0, 200)))
  }
end

types =
  Enum.filter(Xeito.Decisions.all(), fn m -> Keyword.get(Decision.type!(m).policy, :remote) != :forbidden end)

deciders =
  [{:local, :local, []}] ++ for m <- models, do: {String.to_atom(m), :remote_frontier, [model: m]}

try do
  for module <- types do
    type = Decision.type!(module)
    examples = Eval.examples(module, workspaces: workspaces)
    examples = if limit, do: Enum.take(examples, limit), else: examples
    IO.puts("== #{type.name} (#{length(examples)} examples)")

    metrics =
      Map.new(deciders, fn {name, tier, overrides} ->
        {t, results} = :timer.tc(fn -> run.(type, tier, overrides, examples) end, :millisecond)
        m = Map.merge(Eval.metrics(results, Type.values(type)), spend.(results))
        scalars = for {k, v} <- m, not is_map(v) and not is_list(v), do: "#{k}=#{inspect(v)}"
        IO.puts("  #{name} (#{div(t, 1000)} s): #{Enum.join(scalars, " ")}")
        {name, m}
      end)

    report = %{
      type: type.name,
      version: type.version,
      date: Date.to_iso8601(Date.utc_today()),
      examples: length(examples),
      labels: Enum.frequencies_by(examples, & &1.label),
      models: models,
      metrics: metrics
    }

    File.write!(Path.join(out, "#{type.name}.json"), JSON.encode!(report))
  end
after
  File.rm_rf(workspaces)
end
