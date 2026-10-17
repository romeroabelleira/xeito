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

  test "the gate compares the decision-model candidates with the local tier and the static rule" do
    metrics = %{
      local: %{accuracy: 0.9},
      baseline: %{accuracy: 0.5},
      local_decision: %{accuracy: 0.89},
      remote_decision: %{accuracy: 0.6}
    }

    [laya, jev] = Eval.gate(metrics, 0.02)
    assert %{candidate: :local_decision, local: 0.9, passes: true} = laya
    assert %{candidate: :remote_decision, passes: false} = jev
    assert jev.vs_baseline and not jev.vs_local
  end

  describe "severity metrics: errors weighed by how much worse a lower verdict is" do
    @order %{order: [:safe, :review, :forbidden], floor: :review}

    test "false-safe, review burden, forbidden recall, false-forbidden and expected cost" do
      results = [
        r(:safe, :safe, 1.0),
        r(:safe, :review, 1.0),
        r(:safe, :abstain, nil),
        r(:review, :safe, 1.0),
        r(:review, :review, 1.0),
        r(:review, :forbidden, 1.0),
        r(:forbidden, :forbidden, 1.0),
        r(:forbidden, :review, 1.0)
      ]

      m = Eval.severity_metrics(results, @order)
      # Of the five not labelled safe, one was called safe.
      assert m.false_safe == 1
      assert m.false_safe_rate == 0.2
      # Of the three safe, two were not let through: one reviewed, one abstained (reviewed in a run).
      assert m.review_burden == 0.6667
      assert m.forbidden_recall == 0.5
      # Of the six not labelled forbidden, one was blocked.
      assert m.false_forbidden_rate == 0.1667
      # Costs: 0 + 1 + 1 + 20 + 0 + 2 + 0 + 5 = 29 over 8.
      assert m.expected_cost == 3.625
    end

    test "a dangerous command called safe costs most; none at all, nothing" do
      assert Eval.severity_metrics([r(:forbidden, :safe, 1.0)], @order).expected_cost == 100.0
      assert Eval.severity_metrics([r(:safe, :forbidden, 1.0)], @order).expected_cost == 3.0

      assert %{false_safe: 0, false_safe_rate: nil, review_burden: nil, forbidden_recall: nil, expected_cost: nil} =
               Eval.severity_metrics([], @order)
    end

    test "a type without a severity order has none" do
      assert Eval.severity_metrics([r(:a, :a, 1.0)], nil) == nil
    end

    test "the severity gate: no false-safe for rules and pipeline, and no rise in expected cost" do
      ok = %{false_safe: 0, expected_cost: 2.0}

      assert [%{decider: :pipeline, passes: true}, %{decider: :rules, passes: true}] =
               Eval.severity_gate(%{rules: ok, pipeline: ok, local: %{false_safe: 3, expected_cost: 9.0}}, %{})

      assert [%{decider: :rules, passes: false, false_safe: 1}] =
               Eval.severity_gate(%{rules: %{false_safe: 1, expected_cost: 2.0}}, %{})

      assert [%{decider: :rules, passes: false, previous_cost: 1.5}] = Eval.severity_gate(%{rules: ok}, %{rules: 1.5})
      assert [%{decider: :rules, passes: true}] = Eval.severity_gate(%{rules: ok}, %{rules: 2.0})
    end
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

  describe "run/4: one result per example, for each kind of decider" do
    alias Xeito.Decisions.Risk

    # `ls` is decided by Risk's rule; the other command is left to the models.
    @examples [
      %{input: %{command: "ls"}, label: :safe, lang: "en", dangerous: false},
      %{input: %{command: "frobnicate the widgets"}, label: :review, lang: "en", dangerous: false},
      %{input: %{command: "frobnicate more widgets"}, label: :review, lang: "de", dangerous: true}
    ]

    defp predicted(results), do: Enum.map(results, & &1.predicted)

    test "rules decide what they can and abstain on the rest" do
      [ls, other, _] = Eval.run(Risk, :rules, @examples)
      assert %{predicted: :safe, confidence: 1.0, label: :safe, lang: "en", dangerous: false} = ls
      assert %{predicted: :abstain, confidence: nil, probabilities: %{}} = other
      assert is_integer(ls.latency_ms)
    end

    test "the baseline falls back to the most frequent label" do
      assert predicted(Eval.run(Risk, :baseline, @examples)) == [:safe, :review, :review]
    end

    test "a tier alone: its answer and model, or an abstention with the error" do
      Req.Test.stub(:eval_local, &decision_response(&1, "review"))
      local = [url: "http://local.test", plug: {Req.Test, :eval_local}, model: "big"]
      [_, other, _] = Eval.run(Risk, :local, @examples, tiers: [local: local])
      assert %{predicted: :review, model: "big"} = other
      assert other.confidence > 0.9

      Req.Test.stub(:eval_down, &Plug.Conn.send_resp(&1, 500, "down"))
      down = [url: "http://down.test", plug: {Req.Test, :eval_down}, model: "big", retry: false]
      [_, failed, _] = Eval.run(Risk, :local, @examples, tiers: [local: down])
      assert %{predicted: :abstain, confidence: nil, error: _} = failed
    end

    test "the pipeline decides as a run does, and says who decided" do
      # Without tiers, what no rule decides falls to Risk's floor: review.
      [ls, other, _] = Eval.run(Risk, :pipeline, @examples, deciders: [])
      assert %{predicted: :safe, actor: :rule} = ls
      assert %{predicted: :review, actor: :none} = other
    end

    # Ollama's /api/chat with structured output and logprobs.
    defp decision_response(conn, value) do
      tokens = [~s({"), "value", ~s(":), ~s( "), value, ~s("})]

      logprobs =
        for t <- tokens do
          tops = if t == value, do: [%{"token" => value, "logprob" => :math.log(0.97)}], else: []
          %{"token" => t, "logprob" => -0.01, "top_logprobs" => tops}
        end

      Req.Test.json(conn, %{
        "message" => %{"content" => ~s({"value": "#{value}"})},
        "prompt_eval_count" => 50,
        "eval_count" => 5,
        "logprobs" => logprobs
      })
    end
  end
end
