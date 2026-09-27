defmodule Xeito.TiersTest do
  use ExUnit.Case, async: true

  alias Xeito.{Decider, Decision}
  alias Xeito.Decisions.Triage
  alias Xeito.Tiers.{Large, Remote, Small, SystemOne}

  @input %{test: "CheckoutTest", output: "left: 107.0 right: 108.0", diff_stat: "lib/pricing.ex"}

  defp type, do: Decision.type!(Triage)

  defp cfg(stub, extra \\ []),
    do: [url: "http://tier.test", api_key: "k", plug: {Req.Test, stub}] ++ extra

  defp body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {JSON.decode!(raw), conn}
  end

  test "SystemOne sends a pinned choice question and returns the probabilities" do
    Req.Test.stub(:laya, fn conn ->
      {req, conn} = body(conn)
      assert conn.request_path == "/v1/systemone"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer k"]
      assert req["model"] == "multilingual"
      assert req["state"]["output"] =~ "107.0"

      Req.Test.json(conn, %{
        "answers" => %{
          "triage" => %{
            "choice" => "code_bug",
            "probabilities" => %{
              "flaky" => 0.1,
              "code_bug" => 0.8,
              "test_bug" => 0.05,
              "env_problem" => 0.05
            }
          }
        },
        "routing" => %{"model" => "multilingual"}
      })
    end)

    assert {:ok, %{value: :code_bug, confidence: 0.8, model: "laya-multilingual"}} =
             SystemOne.decide(type(), @input, cfg(:laya))
  end

  test "Small prefills the value, scores one token and resolves ambiguous prefixes" do
    ambiguous = Decision.type!(Xeito.TestMachines.AmbiguousType)

    Req.Test.stub(:llama, fn conn ->
      {req, conn} = body(conn)

      case conn.request_path do
        "/apply-template" ->
          assert req["chat_template_kwargs"] == %{"enable_thinking" => false}
          Req.Test.json(conn, %{"prompt" => "<prompt>"})

        "/completion" ->
          assert req["n_predict"] == 1

          tops =
            if String.ends_with?(req["prompt"], ~s({"value": "test)),
              do: [{"_bug", 0.75}, {"_flaky", 0.25}],
              else: [{"test", 0.6}, {"env", 0.3}, {"The", 0.1}]

          Req.Test.json(conn, %{
            "completion_probabilities" => [
              %{
                "top_logprobs" =>
                  Enum.map(tops, fn {t, p} -> %{"token" => t, "logprob" => :math.log(p)} end)
              }
            ]
          })
      end
    end)

    assert {:ok, %{value: :test_bug, probabilities: probs}} =
             Small.decide(ambiguous, %{output: "x"}, cfg(:llama))

    assert_in_delta probs[:test_bug], 0.6 * 0.75 / 0.9, 1.0e-9
    assert_in_delta probs[:test_flaky], 0.6 * 0.25 / 0.9, 1.0e-9
    assert_in_delta probs[:env_problem], 0.3 / 0.9, 1.0e-9
  end

  test "Large reads logprobs at the value position" do
    Req.Test.stub(:ollama, fn conn ->
      {req, conn} = body(conn)
      assert req["format"]["properties"]["value"]["enum"] |> length() == 4
      assert req["logprobs"] == true

      tokens = [
        {~s({"), []},
        {"value", []},
        {~s(":), []},
        {~s( "), []},
        {"code", [{"code", 0.9}, {"test", 0.08}, {"The", 0.02}]},
        {"_bug", []},
        {~s("}), []}
      ]

      Req.Test.json(conn, %{
        "message" => %{"content" => ~s({"value": "code_bug"})},
        "logprobs" =>
          Enum.map(tokens, fn {t, tops} ->
            %{
              "token" => t,
              "logprob" => -0.01,
              "top_logprobs" =>
                Enum.map(tops, fn {tt, p} -> %{"token" => tt, "logprob" => :math.log(p)} end)
            }
          end)
      })
    end)

    assert {:ok, %{value: :code_bug, confidence: c, probabilities: probs}} =
             Large.decide(type(), @input, cfg(:ollama, model: "big"))

    assert_in_delta c, 0.9 / 0.98, 1.0e-9
    assert_in_delta probs[:test_bug], 0.08 / 0.98, 1.0e-9
  end

  test "Remote sends structured output with refusal fallback and prices usage" do
    Req.Test.stub(:anthropic, fn conn ->
      {req, conn} = body(conn)
      assert conn.request_path == "/v1/messages"
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["k"]
      assert Plug.Conn.get_req_header(conn, "anthropic-version") == ["2023-06-01"]

      assert Plug.Conn.get_req_header(conn, "anthropic-beta") == [
               "server-side-fallback-2026-07-01"
             ]

      assert req["model"] == "claude-opus-5"
      assert req["fallbacks"] == "default"
      assert req["output_config"]["effort"] == "low"
      assert req["output_config"]["format"]["type"] == "json_schema"

      assert req["output_config"]["format"]["schema"]["properties"]["value"]["enum"] |> length() ==
               4

      Req.Test.json(conn, %{
        "model" => "claude-opus-5",
        "stop_reason" => "end_turn",
        "content" => [%{"type" => "text", "text" => ~s({"value": "code_bug"})}],
        "usage" => %{"input_tokens" => 1_000, "output_tokens" => 100}
      })
    end)

    assert {:ok, %{value: :code_bug, confidence: nil, terminal: true, cost: cost}} =
             Remote.decide(type(), @input, cfg(:anthropic))

    assert cost == %{tokens_in: 1_000, tokens_out: 100, usd: 0.0075}
  end

  test "Remote treats a refusal as an error, not a value" do
    Req.Test.stub(:anthropic_refusal, fn conn ->
      Req.Test.json(conn, %{
        "stop_reason" => "refusal",
        "stop_details" => %{"category" => "cyber"},
        "content" => []
      })
    end)

    assert {:error, {:refusal, %{"category" => "cyber"}}} =
             Remote.decide(type(), @input, cfg(:anthropic_refusal))
  end

  describe "Decider" do
    test "a low-confidence tier falls through to the next; evidence keeps the attempt" do
      Req.Test.stub(:laya_low, fn conn ->
        Req.Test.json(conn, %{
          "answers" => %{
            "triage" => %{
              "choice" => "flaky",
              "probabilities" => %{"flaky" => 0.5, "code_bug" => 0.5}
            }
          }
        })
      end)

      Req.Test.stub(:llama_high, fn conn ->
        case conn.request_path do
          "/apply-template" ->
            Req.Test.json(conn, %{"prompt" => "p"})

          "/completion" ->
            Req.Test.json(conn, %{
              "completion_probabilities" => [
                %{
                  "top_logprobs" => [
                    %{"token" => "code", "logprob" => :math.log(0.95)},
                    %{"token" => "fl", "logprob" => :math.log(0.05)}
                  ]
                }
              ]
            })
        end
      end)

      decision =
        Decider.decide(Triage, @input,
          deciders: [:system_one, :small],
          tiers: [system_one: cfg(:laya_low), small: cfg(:llama_high, model: "qwen-small")]
        )

      assert %Decision{value: :code_bug, actor: :small, model: "qwen-small"} = decision
      assert_in_delta decision.confidence, 0.95, 1.0e-9
      assert [%{tier: :system_one, confidence: 0.5}] = decision.evidence
    end

    test "rules decide before any tier" do
      decision =
        Decider.decide(Triage, %{test: "t", output: "** (Mix) could not be found"},
          deciders: [:system_one]
        )

      assert %Decision{value: :env_problem, actor: :rule, confidence: 1.0} = decision
    end

    test "unavailable tiers are skipped and the decision abstains" do
      decision = Decider.decide(Triage, @input, deciders: [:system_one, :small])
      assert %Decision{value: :abstain, actor: :none} = decision
      assert Enum.all?(decision.evidence, &(&1.error == :tier_unavailable))
      assert is_binary(decision.input_hash)
      assert decision.type_version == "1"
    end
  end
end
