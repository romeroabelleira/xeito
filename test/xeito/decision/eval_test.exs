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
