defmodule Xeito.Decision.Eval do
  @moduledoc """
  Evaluates deciders on a decision type's labelled examples
  (`priv/decisions/<type>/examples.jsonl`) and applies the gate test.

  Deciders:

    * `:rules` — the type's rules only (abstains when no rule fires)
    * `:baseline` — the *static rule*: rules, else the most frequent label
    * `:system_one`, `:small`, `:large` — one model tier, evaluated alone
    * `:pipeline` — `Xeito.Decider.decide/3` as a run uses it (rules → tiers → floor)

  Metrics:
    * accuracy (an abstention counts as wrong), coverage, and accuracy on the answered subset
    * macro-F1
    * ECE (10 bins), raw and after temperature scaling (2-fold: fit T on one half, measure on the other)
    * latency p50/p95, accuracy per language, and the confusion pairs

  Gate (`docs/architecture/03-typed-decisions.md#the-gate-test`): a small candidate passes if
  its accuracy is within `margin` of the large tier and at least `margin` above the static rule.
  """

  alias Xeito.Decider
  alias Xeito.Decision
  alias Xeito.Decision.Type

  @doc "Loads the labelled examples of a decision type."
  @spec examples(module()) :: [map()]
  def examples(type_module) do
    type = Decision.type!(type_module)
    path = Application.app_dir(:xeito, ["priv", "decisions", type.name, "examples.jsonl"])

    path
    |> File.stream!()
    |> Enum.map(&JSON.decode!/1)
    |> Enum.map(fn ex ->
      {:ok, label} = Type.cast(type, ex["label"])

      %{
        input: atomize(ex["input"], type),
        label: label,
        lang: ex["lang"],
        source: ex["source"],
        dangerous: ex["dangerous"] == true
      }
    end)
  end

  defp atomize(input, type) do
    names = Map.new(type.inputs, &{Atom.to_string(&1.name), &1.name})
    for {k, v} <- input, Map.has_key?(names, k), into: %{}, do: {names[k], v}
  end

  @doc "Runs one decider over the examples. Returns one result per example."
  @spec run(module(), atom(), [map()], keyword()) :: [map()]
  def run(type_module, decider, examples, opts \\ []) do
    type = Decision.type!(type_module)
    majority = examples |> Enum.frequencies_by(& &1.label) |> Enum.max_by(&elem(&1, 1)) |> elem(0)

    Enum.map(examples, fn ex ->
      normalized = Type.normalize_input(type, ex.input)
      started = System.monotonic_time(:millisecond)
      outcome = predict(type_module, type, decider, ex.input, normalized, majority, opts)
      latency = System.monotonic_time(:millisecond) - started

      Map.merge(
        %{label: ex.label, lang: ex.lang, latency_ms: latency, dangerous: ex.dangerous},
        outcome
      )
    end)
  end

  defp predict(_mod, type, decider, _input, normalized, majority, _opts) when decider in [:rules, :baseline] do
    case Decider.apply_rules(type, normalized) do
      {:ok, value, _} -> certain(value)
      :none -> without_rule(decider, majority)
    end
  end

  defp predict(mod, _type, :pipeline, input, _normalized, _majority, opts) do
    d = Decider.decide(mod, input, Keyword.take(opts, [:deciders, :tiers]))

    %{
      predicted: d.value,
      confidence: d.confidence,
      probabilities: d.probabilities,
      actor: d.actor
    }
  end

  defp predict(_mod, type, tier, _input, normalized, _majority, opts) do
    case Decider.run_tier(type, tier, normalized, get_in(opts, [:tiers, tier]) || []) do
      {:ok, r} ->
        %{
          predicted: r.value,
          confidence: r.confidence,
          probabilities: r.probabilities,
          model: r.model
        }

      {:error, reason} ->
        %{predicted: :abstain, confidence: nil, probabilities: %{}, error: inspect(reason)}
    end
  end

  defp certain(value), do: %{predicted: value, confidence: 1.0, probabilities: %{value => 1.0}}

  # Where no rule fires, rules alone abstain; the static rule answers the most frequent label.
  defp without_rule(:rules, _majority), do: %{predicted: :abstain, confidence: nil, probabilities: %{}}
  defp without_rule(:baseline, majority), do: certain(majority)

  @doc "Metrics for one decider's results."
  @spec metrics([map()], [atom()]) :: map()
  def metrics(results, values) do
    n = length(results)
    answered = Enum.reject(results, &(&1.predicted == :abstain))
    correct = Enum.count(results, &(&1.predicted == &1.label))
    latencies = Enum.map(results, & &1.latency_ms)
    {temperature, ece_cal} = calibrated_ece(answered, values)

    %{
      n: n,
      accuracy: ratio(correct, n),
      coverage: ratio(length(answered), n),
      accuracy_answered: ratio(correct, length(answered)),
      macro_f1: macro_f1(results, values),
      ece: ece(answered),
      ece_calibrated: ece_cal,
      temperature: temperature,
      p50_ms: percentile(latencies, 50),
      p95_ms: percentile(latencies, 95),
      by_lang:
        results
        |> Enum.group_by(& &1.lang)
        |> Map.new(fn {l, rs} ->
          {l, ratio(Enum.count(rs, &(&1.predicted == &1.label)), length(rs))}
        end),
      confusions:
        results
        |> Enum.reject(&(&1.predicted == &1.label))
        |> Enum.frequencies_by(&"#{&1.label}->#{&1.predicted}")
    }
  end

  @doc "Macro-averaged F1 over the type's values (abstentions count as misses)."
  @spec macro_f1([map()], [atom()]) :: float()
  def macro_f1(results, values) do
    values
    |> Enum.map(fn v ->
      tp = Enum.count(results, &(&1.predicted == v and &1.label == v))
      fp = Enum.count(results, &(&1.predicted == v and &1.label != v))
      fn_ = Enum.count(results, &(&1.predicted != v and &1.label == v))
      if 2 * tp + fp + fn_ == 0, do: 1.0, else: 2 * tp / (2 * tp + fp + fn_)
    end)
    |> mean()
  end

  @doc "Expected calibration error over 10 equal-width confidence bins."
  @spec ece([map()]) :: float() | nil
  def ece([]), do: nil

  def ece(results) do
    n = length(results)

    results
    |> Enum.filter(&is_number(&1.confidence))
    |> Enum.group_by(&min(trunc(&1.confidence * 10), 9))
    |> Enum.map(fn {_bin, rs} ->
      acc = Enum.count(rs, &(&1.predicted == &1.label)) / length(rs)
      conf = rs |> Enum.map(& &1.confidence) |> mean()
      length(rs) / n * abs(acc - conf)
    end)
    |> Enum.sum()
    |> Float.round(4)
  end

  @temperatures [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0]

  # Fits a temperature on each half and measures ECE on the other half.
  defp calibrated_ece(results, values) do
    usable = Enum.filter(results, &(map_size(&1.probabilities) > 0))

    if length(usable) < 10 do
      {nil, nil}
    else
      {a, b} = usable |> Enum.with_index() |> Enum.split_with(fn {_, i} -> rem(i, 2) == 0 end)
      {a, b} = {Enum.map(a, &elem(&1, 0)), Enum.map(b, &elem(&1, 0))}
      ece_b = b |> Enum.map(&rescale(&1, fit(a, values), values)) |> ece()
      ece_a = a |> Enum.map(&rescale(&1, fit(b, values), values)) |> ece()
      {fit(usable, values), Float.round((ece_a + ece_b) / 2, 4)}
    end
  end

  defp fit(results, values), do: Enum.min_by(@temperatures, &nll(results, &1, values))

  defp nll(results, t, values) do
    results
    |> Enum.map(fn r ->
      -:math.log(max(scaled(r.probabilities, t, values)[r.label] || 1.0e-9, 1.0e-9))
    end)
    |> Enum.sum()
  end

  defp rescale(r, t, values) do
    probs = scaled(r.probabilities, t, values)
    {value, conf} = Enum.max_by(probs, &elem(&1, 1))
    %{r | predicted: value, confidence: conf, probabilities: probs}
  end

  defp scaled(probs, t, values) do
    raw = Map.new(values, fn v -> {v, :math.pow(max(Map.get(probs, v, 0.0), 1.0e-6), 1 / t)} end)
    total = raw |> Map.values() |> Enum.sum()
    Map.new(raw, fn {v, p} -> {v, p / total} end)
  end

  @doc """
  The gate test. `metrics_by_decider` maps deciders to `metrics/2` output. Candidates are the
  small tiers present. Returns one verdict per candidate.
  """
  @spec gate(%{atom() => map()}, float()) :: [map()]
  def gate(metrics_by_decider, margin \\ 0.02) do
    large = get_in(metrics_by_decider, [:large, :accuracy])
    baseline = get_in(metrics_by_decider, [:baseline, :accuracy])

    for candidate <- [:system_one, :small], m = metrics_by_decider[candidate], m != nil do
      vs_large = if large, do: m.accuracy >= large - margin
      vs_baseline = if baseline, do: m.accuracy >= baseline + margin

      %{
        candidate: candidate,
        accuracy: m.accuracy,
        large: large,
        baseline: baseline,
        margin: margin,
        passes: vs_large == true and vs_baseline == true,
        vs_large: vs_large,
        vs_baseline: vs_baseline
      }
    end
  end

  @doc """
  Selective-prediction cascade: answer with the small tier when its confidence ≥ θ, otherwise
  ask the large tier (`docs/architecture/04-delegation.md#tuning-thresholds-from-the-log`).

  θ is chosen as the lowest threshold whose cascade accuracy stays within `epsilon` of
  large-only accuracy, i.e. the one that sends the most decisions to the small tier. It is fitted
  on one half of the examples and measured on the other (2-fold), so the reported accuracy and
  small-tier share are held out. `small` and `large` are `run/4` results over the same examples.
  """
  @spec cascade([map()], [map()], float()) :: map()
  def cascade(small, large, epsilon \\ 0.01) do
    pairs = Enum.zip(small, large)
    {a, b} = pairs |> Enum.with_index() |> Enum.split_with(fn {_, i} -> rem(i, 2) == 0 end)
    {a, b} = {Enum.map(a, &elem(&1, 0)), Enum.map(b, &elem(&1, 0))}

    folds = [{fit_threshold(a, epsilon), b}, {fit_threshold(b, epsilon), a}]
    held_out = Enum.map(folds, fn {theta, test} -> cascade_at(test, theta) end)
    n = length(pairs)

    %{
      epsilon: epsilon,
      thresholds: Enum.map(folds, &elem(&1, 0)),
      threshold_all: fit_threshold(pairs, epsilon),
      accuracy: held_out |> Enum.map(& &1.correct) |> Enum.sum() |> ratio(n),
      small_share: held_out |> Enum.map(& &1.small) |> Enum.sum() |> ratio(n),
      large_accuracy: pairs |> Enum.count(fn {_, l} -> l.predicted == l.label end) |> ratio(n),
      small_accuracy: pairs |> Enum.count(fn {s, _} -> s.predicted == s.label end) |> ratio(n)
    }
  end

  @thresholds [0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95, 0.97, 0.99, 0.999, 1.01]

  defp fit_threshold(pairs, epsilon) do
    large_acc = Enum.count(pairs, fn {_, l} -> l.predicted == l.label end) / max(length(pairs), 1)

    Enum.find(@thresholds, 1.01, fn theta ->
      %{correct: c} = cascade_at(pairs, theta)
      c / max(length(pairs), 1) >= large_acc - epsilon
    end)
  end

  defp cascade_at(pairs, theta) do
    Enum.reduce(pairs, %{correct: 0, small: 0}, fn {s, l}, acc ->
      use_small = is_number(s.confidence) and s.confidence >= theta and s.predicted != :abstain
      prediction = if use_small, do: s, else: l

      %{
        correct: acc.correct + if(prediction.predicted == prediction.label, do: 1, else: 0),
        small: acc.small + if(use_small, do: 1, else: 0)
      }
    end)
  end

  defp ratio(_a, 0), do: nil
  defp ratio(a, b), do: Float.round(a / b, 4)

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)

  defp percentile([], _p), do: nil

  defp percentile(list, p) do
    sorted = Enum.sort(list)
    Enum.at(sorted, min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1))))
  end
end
