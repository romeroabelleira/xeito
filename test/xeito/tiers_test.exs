defmodule Xeito.TiersTest do
  use ExUnit.Case, async: true

  alias Xeito.Decider
  alias Xeito.Decision
  alias Xeito.Decisions.Triage
  alias Xeito.Tiers.Large
  alias Xeito.Tiers.OpenRouter
  alias Xeito.Tiers.Remote
  alias Xeito.Tiers.Small
  alias Xeito.Tiers.SystemOne

  @input %{test: "CheckoutTest", output: "left: 107.0 right: 108.0", diff_stat: "lib/pricing.ex"}

  defp type, do: Decision.type!(Triage)

  defp cfg(stub, extra \\ []), do: [url: "http://tier.test", api_key: "k", plug: {Req.Test, stub}] ++ extra

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
                "top_logprobs" => Enum.map(tops, fn {t, p} -> %{"token" => t, "logprob" => :math.log(p)} end)
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
      assert length(req["format"]["properties"]["value"]["enum"]) == 4
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
              "top_logprobs" => Enum.map(tops, fn {tt, p} -> %{"token" => tt, "logprob" => :math.log(p)} end)
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

      assert length(req["output_config"]["format"]["schema"]["properties"]["value"]["enum"]) ==
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

  defp openai_logprobs do
    for t <- [~s({"), "value", ~s(":), ~s( "), "code", "_bug", ~s("})] do
      tops =
        if t == "code",
          do: [
            %{"token" => "code", "logprob" => :math.log(0.9)},
            %{"token" => "test", "logprob" => :math.log(0.06)},
            %{"token" => "fl", "logprob" => :math.log(0.02)}
          ],
          else: []

      %{"token" => t, "logprob" => -0.01, "top_logprobs" => tops}
    end
  end

  test "OpenRouter requires schema + logprobs endpoints, denies data collection, scores logprobs" do
    Req.Test.stub(:openrouter, fn conn ->
      {req, conn} = body(conn)
      assert conn.request_path == "/v1/chat/completions"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer k"]
      assert req["model"] == "qwen/qwen3.6-35b-a3b"
      assert req["response_format"]["type"] == "json_schema"
      assert req["response_format"]["json_schema"]["strict"] == true

      assert length(req["response_format"]["json_schema"]["schema"]["properties"]["value"]["enum"]) == 4

      assert req["logprobs"] == true and req["top_logprobs"] == 20
      assert req["temperature"] == 0
      assert req["reasoning"] == %{"enabled" => false}

      assert req["provider"] == %{
               "require_parameters" => true,
               "data_collection" => "deny",
               "zdr" => true,
               "only" => ["Parasail"]
             }

      Req.Test.json(conn, %{
        "model" => "qwen/qwen3.6-35b-a3b",
        "provider" => "Parasail",
        "choices" => [
          %{
            "message" => %{"content" => ~s({"value": "code_bug"})},
            "logprobs" => %{"content" => openai_logprobs()}
          }
        ],
        "usage" => %{"prompt_tokens" => 310, "completion_tokens" => 7, "cost" => 0.0000535}
      })
    end)

    cfg = cfg(:openrouter, model: "qwen/qwen3.6-35b-a3b", providers: ["Parasail"])

    assert {:ok, %{value: :code_bug, confidence: c, probabilities: probs, cost: cost} = r} =
             OpenRouter.decide(type(), @input, cfg)

    assert_in_delta c, 0.9 / 0.98, 1.0e-9
    assert_in_delta probs[:test_bug], 0.06 / 0.98, 1.0e-9
    assert r.model == "openrouter:qwen/qwen3.6-35b-a3b@Parasail"
    refute Map.has_key?(r, :terminal)
    assert cost == %{tokens_in: 310, tokens_out: 7, usd: 0.0000535}
  end

  test "OpenRouter without logprobs is terminal; a refusal is an error" do
    Req.Test.stub(:openrouter_plain, fn conn ->
      Req.Test.json(conn, %{
        "model" => "some/model",
        "choices" => [%{"message" => %{"content" => ~s({"value": "flaky"})}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 3, "cost" => 0.00001}
      })
    end)

    assert {:ok, %{value: :flaky, confidence: nil, terminal: true, model: "openrouter:some/model"}} =
             OpenRouter.decide(type(), @input, cfg(:openrouter_plain, model: "some/model"))

    Req.Test.stub(:openrouter_refusal, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => nil, "refusal" => "I can't help with that."}}]
      })
    end)

    assert {:error, {:refusal, _}} =
             OpenRouter.decide(type(), @input, cfg(:openrouter_refusal, model: "some/model"))
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
        Decider.decide(Triage, %{test: "t", output: "** (Mix) could not be found"}, deciders: [:system_one])

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

  describe "tiers that fail, and answers in unusual shapes" do
    defp failing(stub, how) do
      Req.Test.stub(stub, fn conn ->
        case how do
          {:status, status} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "no"})
          :down -> Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      cfg(stub, model: "m", retry: false)
    end

    test "an HTTP error or a transport error is an error, for Large and System One" do
      assert {:error, {:http, 500, _}} = Large.decide(type(), @input, failing(:large_500, {:status, 500}))

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Large.decide(type(), @input, failing(:large_down, :down))

      assert {:error, {:http, 503, _}} = SystemOne.decide(type(), @input, failing(:s1_503, {:status, 503}))
      assert {:error, %Req.TransportError{}} = SystemOne.decide(type(), @input, failing(:s1_down, :down))
    end

    test "OpenRouter's key check: the key's data, an HTTP error, or a transport error" do
      Req.Test.stub(:or_key, fn conn -> Req.Test.json(conn, %{"data" => %{"limit" => 10, "usage" => 1.5}}) end)
      assert {:ok, %{"limit" => 10}} = OpenRouter.key_info(cfg(:or_key))
      assert {:error, {:http, 401, _}} = OpenRouter.key_info(failing(:or_401, {:status, 401}))
      assert {:error, %Req.TransportError{}} = OpenRouter.key_info(failing(:or_down, :down))
    end

    test "System One without probabilities or routing: the choice alone, under the configured model" do
      Req.Test.stub(:s1_choice, fn conn -> Req.Test.json(conn, %{"answers" => %{"triage" => %{"choice" => "flaky"}}}) end)

      assert {:ok, %{value: :flaky, confidence: 1.0, model: "laya-multilingual"}} =
               SystemOne.decide(type(), @input, cfg(:s1_choice))
    end

    test "Large's probabilities: from the value's own tokens, from the answer alone, or none" do
      token = fn t, lp -> %{"token" => t, "logprob" => lp, "top_logprobs" => []} end
      prefix = [token.(~s({"), 0.0), token.("value", 0.0), token.(~s(":), 0.0), token.(~s( "), 0.0)]

      # No usable alternatives at the value: the chosen value's own probability.
      own =
        Large.probabilities(
          ~s({"value": "flaky"}),
          prefix ++ [token.("fl", -0.1), token.("aky", -0.2), token.(~s("}), 0.0)],
          type()
        )

      assert_in_delta own["flaky"], :math.exp(-0.3), 1.0e-9

      # No logprobs at all: the answer counts as certain.
      assert Large.probabilities(~s({"value": "flaky"}), [], type()) == %{"flaky" => 1.0}

      # Not JSON, or JSON without a value: no probabilities.
      assert Large.probabilities("not json", prefix, type()) == %{}
      assert Large.probabilities(~s({"other": 1}), prefix, type()) == %{}
      assert Large.probabilities("not json", [], type()) == %{}
    end
  end
end
