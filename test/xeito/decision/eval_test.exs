defmodule Xeito.Decision.EvalTest do
  use ExUnit.Case, async: true

  alias Xeito.Decision.Eval

  defp r(label, predicted, confidence, probs \\ %{}),
    do: %{label: label, predicted: predicted, confidence: confidence, probabilities: probs, latency_ms: 10, lang: "en"}

  test "accuracy counts abstentions as wrong; coverage and answered accuracy separate them" do
    m =
      Eval.metrics([r(:a, :a, 0.9), r(:b, :abstain, nil), r(:a, :b, 0.6), r(:b, :b, 0.8)], [
        :a,
        :b
      ])

    assert m.accuracy == 0.5
    assert m.coverage == 0.75
    assert m.accuracy_answered == 0.6667
    assert m.confusions == %{"a->b" => 1, "b->abstain" => 1}
  end

  test "macro-F1 averages per-value F1" do
    assert Eval.macro_f1([r(:a, :a, 1.0), r(:a, :b, 1.0), r(:b, :b, 1.0)], [:a, :b]) ==
             2 / 3
  end

  test "ECE is zero for perfectly calibrated bins and positive for overconfidence" do
    assert Eval.ece([r(:a, :a, 1.0), r(:b, :b, 1.0)]) == 0.0
    assert Eval.ece([r(:a, :b, 0.95), r(:a, :a, 0.95)]) == 0.45
  end

  test "the gate compares candidates with the large tier and the static rule" do
    metrics = %{
      large: %{accuracy: 0.9},
      baseline: %{accuracy: 0.5},
      system_one: %{accuracy: 0.89},
      small: %{accuracy: 0.6}
    }

    [s1, small] = Eval.gate(metrics, 0.02)
    assert s1.passes
    refute small.passes
    assert small.vs_baseline and not small.vs_large
  end

  test "loads every built-in example set with valid labels" do
    for type <- Xeito.Decisions.all() do
      examples = Eval.examples(type)
      assert length(examples) >= 40, "#{inspect(type)} has #{length(examples)} examples"
    end
  end

  test "the cascade picks the lowest threshold that keeps accuracy within epsilon, held out" do
    # Small is right when confident (>= 0.9) and wrong otherwise; large is always right.
    small =
      for i <- 1..40 do
        # Confident and unconfident answers alternate in pairs, so both folds see both kinds.
        conf = if rem(div(i, 2), 2) == 0, do: 0.95, else: 0.6
        r(:a, if(conf >= 0.9, do: :a, else: :b), conf)
      end

    large = for _ <- 1..40, do: r(:a, :a, 0.99)
    c = Eval.cascade(small, large, 0.0)

    assert c.accuracy == 1.0
    assert c.small_share == 0.5
    assert Enum.all?(c.thresholds, &(&1 > 0.6 and &1 <= 0.95))
  end
end
