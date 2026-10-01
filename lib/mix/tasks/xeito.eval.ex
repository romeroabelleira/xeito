defmodule Mix.Tasks.Xeito.Eval do
  @shortdoc "Evaluates deciders on a decision type's labelled examples"
  @moduledoc """
  Evaluates deciders on labelled examples and applies the gate test.

      mix xeito.eval triage risk --deciders baseline,rules,system_one,small,large,pipeline
      mix xeito.eval intent --limit 20 --out bench/decisions
      mix xeito.eval triage --deciders large --predictions large
      mix xeito.eval done --deciders system_one,small,large --epsilon 0.01


  Decision types: intent, triage, risk, done.
  Tier endpoints come from the environment (see `config/runtime.exs`). With `--out DIR`, a JSON
  report per type is written to `DIR/<type>.json`. With `--predictions TIER`, that tier's
  per-example verdicts are written to `DIR/<type>.<tier>.jsonl` (input, label, value,
  probabilities): distillation data for fine-tuning smaller deciders (P7).

  When a local first stage (`system_one`, `small`) is evaluated with `large` or `openrouter`, the
  report includes the selective-prediction cascade for each pair (`"small→large"`, …;
  `Xeito.Decision.Eval.cascade/3`, tolerance `--epsilon`, default 0.01).

  Off-box tiers (`openrouter`, `remote`) are skipped for types whose policy forbids them (Risk).
  """

  use Mix.Task

  alias Xeito.Decision
  alias Xeito.Decision.Eval
  alias Xeito.Decision.Type
  alias Xeito.Log.Codec
  alias Xeito.Policy

  @switches [
    deciders: :string,
    limit: :integer,
    out: :string,
    margin: :float,
    predictions: :string,
    epsilon: :float
  ]

  @impl true
  def run(args) do
    {opts, names, _} = OptionParser.parse(args, strict: @switches)
    Mix.Task.run("app.start")

    deciders =
      opts
      |> Keyword.get(:deciders, "baseline,rules,system_one,small,large,pipeline")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_existing_atom/1)

    for name <- names do
      module = Xeito.Decisions.fetch!(name)
      {report, results} = evaluate(module, deciders, opts)
      print(report)
      if out = opts[:out], do: write(out, report)

      tier = opts[:predictions]

      if tier && Map.has_key?(results, String.to_existing_atom(tier)),
        do: write_predictions(opts[:out] || ".", report.type, tier, results)
    end
  end

  defp evaluate(module, deciders, opts) do
    type = Decision.type!(module)
    deciders = permitted(type, deciders)
    examples = module |> Eval.examples() |> maybe_limit(opts[:limit])

    results = Map.new(deciders, &{&1, Eval.run(module, &1, examples)})
    metrics = Map.new(results, fn {d, rs} -> {d, Eval.metrics(rs, Type.values(type))} end)

    report = %{
      type: type.name,
      version: type.version,
      date: Date.to_iso8601(Date.utc_today()),
      examples: length(examples),
      labels: Enum.frequencies_by(examples, & &1.label),
      metrics: metrics,
      gate: Eval.gate(metrics, Keyword.get(opts, :margin, 0.02)),
      cascade: cascades(results, Keyword.get(opts, :epsilon, 0.01)),
      dangerous_missed:
        (
          for_result =
            for(
              {_, rs} <- Map.take(results, [:rules]),
              r <- rs,
              r.dangerous and r.predicted != :forbidden,
              do: r
            )

          length(for_result)
        )
    }

    {report, Map.new(results, fn {d, rs} -> {d, Enum.zip(examples, rs)} end)}
  end

  defp write_predictions(dir, type, tier, results) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{type}.#{tier}.jsonl")

    lines =
      for {ex, r} <- Map.fetch!(results, String.to_existing_atom(tier)) do
        %{
          input: ex.input,
          label: ex.label,
          value: r.predicted,
          confidence: r.confidence,
          probabilities: r.probabilities
        }
        |> Codec.jsonable()
        |> JSON.encode!()
      end

    File.write!(path, Enum.join(lines, "\n") <> "\n")
    Mix.shell().info("  wrote #{path}")
  end

  # Cascades from each local first stage to each stronger tier evaluated alongside it.
  defp cascades(results, epsilon) do
    for small <- [:system_one, :small],
        target <- [:large, :openrouter],
        Map.has_key?(results, small),
        Map.has_key?(results, target),
        into: %{} do
      {"#{small}→#{target}", Eval.cascade(results[small], results[target], epsilon)}
    end
  end

  # Evaluation calls tiers directly, outside the escalation policy, so a type that forbids
  # off-box tiers (Risk) is never sent to them here either. The seed sets are synthetic, but the
  # rule holds for every input.
  defp permitted(type, deciders) do
    if Keyword.get(type.policy, :remote) == :forbidden do
      {skipped, kept} = Enum.split_with(deciders, &(&1 in Policy.off_box_tiers()))

      if skipped != [],
        do: Mix.shell().info("  #{type.name}: skipping #{Enum.join(skipped, ", ")} (policy remote: :forbidden)")

      kept
    else
      deciders
    end
  end

  defp maybe_limit(examples, nil), do: examples
  defp maybe_limit(examples, n), do: examples |> Enum.shuffle() |> Enum.take(n)

  defp print(report) do
    Mix.shell().info("\n#{report.type} v#{report.version}: #{report.examples} examples #{inspect(report.labels)}")

    Mix.shell().info("  decider      acc    cover  acc|ans  macroF1  ECE    ECE(T)  T     p50ms  p95ms")

    for {decider, m} <- Enum.sort_by(report.metrics, &elem(&1, 0)) do
      Mix.shell().info(
        "  " <>
          Enum.map_join(
            [
              {decider, 12},
              {m.accuracy, 6},
              {m.coverage, 6},
              {m.accuracy_answered, 8},
              {Float.round(m.macro_f1, 3), 8},
              {m.ece, 6},
              {m.ece_calibrated, 7},
              {m.temperature, 5},
              {m.p50_ms, 6},
              {m.p95_ms, 6}
            ],
            " ",
            fn {v, w} -> v |> format() |> String.pad_trailing(w) end
          )
      )
    end

    for {path, c} <- report.cascade do
      [first, target] = String.split(path, "→")

      Mix.shell().info(
        "  cascade #{path} (ε #{c.epsilon}): accuracy #{c.accuracy} vs #{target} #{c.large_accuracy}, " <>
          "#{first} answers #{c.small_share} (θ per fold #{inspect(c.thresholds)})"
      )
    end

    for g <- report.gate do
      Mix.shell().info(
        "  gate #{g.candidate}: #{if g.passes, do: "PASS", else: "fail"} (#{g.accuracy} vs large #{inspect(g.large)}, baseline #{inspect(g.baseline)}, margin #{g.margin})"
      )
    end
  end

  defp format(nil), do: "-"
  defp format(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 3)
  defp format(v), do: to_string(v)

  defp write(dir, report) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{report.type}.json")
    File.write!(path, report |> Codec.jsonable() |> JSON.encode!())
    Mix.shell().info("  wrote #{path}")
  end
end
