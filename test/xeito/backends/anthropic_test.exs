defmodule Xeito.Backends.AnthropicTest do
  use ExUnit.Case, async: true

  alias Xeito.Backends.Anthropic
  alias Xeito.Decision
  alias Xeito.Decision.Type
  alias Xeito.Decisions.Triage

  defp type, do: Decision.type!(Triage)
  defp input, do: Type.normalize_input(type(), %{test: "pricing_test", output: "assertion failed"})

  describe "price/1 and cost/2: the published list prices, since the API reports no cost" do
    test "a model in the table is priced per token, with its window and longest answer" do
      price = Anthropic.price("claude-opus-5-5")
      assert_in_delta price.prompt, 4.0e-6, 1.0e-12
      assert_in_delta price.completion, 20.0e-6, 1.0e-12
      assert_in_delta price.cache_read, 0.2e-6, 1.0e-12
      assert price.context == 1_000_000
      assert price.output == 128_000
      assert price.tiers == []
    end

    test "a model not in the table has no price, and costs nothing on paper" do
      assert Anthropic.price("claude-unknown") == nil
      assert Anthropic.cost(nil, %{"input_tokens" => 1000, "output_tokens" => 10}) == 0.0
    end

    test "cost: uncached input at full price, cache reads at theirs, cache writes at 1.25 times, the answer at its price" do
      usage = %{
        "input_tokens" => 1_000_000,
        "cache_read_input_tokens" => 1_000_000,
        "cache_creation_input_tokens" => 1_000_000,
        "output_tokens" => 100_000
      }

      assert_in_delta Anthropic.cost(Anthropic.price("claude-opus-5-5"), usage), 4 + 0.2 + 5 + 2, 1.0e-6
    end

    test "a missing usage field counts as zero" do
      assert_in_delta Anthropic.cost(Anthropic.price("claude-sonnet-5-5"), %{"output_tokens" => 1_000_000}), 10, 1.0e-6
    end

    test "Haiku 5.5 charges a dearer rate once the prompt passes 100k tokens" do
      price = Anthropic.price("claude-haiku-5-5")
      assert [%{from: 100_000}] = price.tiers
      assert_in_delta Anthropic.cost(price, %{"input_tokens" => 100_000}), 0.05, 1.0e-9
      assert_in_delta Anthropic.cost(price, %{"input_tokens" => 200_000, "output_tokens" => 1_000_000}), 0.1 + 2.5, 1.0e-9
    end
  end

  describe "headers/1 and fallbacks?/1" do
    test "the key, the API version, and the fallback beta for the models that take it" do
      assert Anthropic.headers(api_key: "k", model: "claude-opus-5-5") == [
               {"x-api-key", "k"},
               {"anthropic-version", Anthropic.version()},
               {"anthropic-beta", "server-side-fallback-2026-07-01"}
             ]

      assert Anthropic.headers(api_key: "k", model: "claude-haiku-5-5") == [
               {"x-api-key", "k"},
               {"anthropic-version", Anthropic.version()}
             ]
    end

    test "req_options/2: the headers, the base URL, the timeout given unless the tier sets one, no retries, no bearer" do
      opts = Anthropic.req_options([api_key: "k", model: "claude-opus-5-5", url: "http://a.test"], 60_000)
      assert opts[:base_url] == "http://a.test"
      assert opts[:receive_timeout] == 60_000
      assert opts[:retry] == false
      refute Keyword.has_key?(opts, :auth)
      assert {"x-api-key", "k"} in opts[:headers]

      assert Anthropic.req_options([api_key: "k", model: "claude-opus-5-5", url: "u", timeout: 5], 60_000)[
               :receive_timeout
             ] == 5
    end
  end

  describe "body/3" do
    test "the decision's instructions as system, its input as the user message, its schema as the format, low effort" do
      body = Anthropic.body(type(), input(), model: "claude-opus-5-5")

      assert body.model == "claude-opus-5-5"
      assert body.max_tokens == 1024
      assert body.system =~ "You make one typed decision."
      assert [%{role: "user", content: content}] = body.messages
      assert content =~ "pricing_test"
      assert body.output_config.effort == "low"
      assert body.output_config.format == %{type: "json_schema", schema: Xeito.Decision.Prompt.json_schema(type())}
      assert body.fallbacks == "default"
      refute Map.has_key?(body, :temperature)
    end

    test "a model without server-side fallbacks asks for none; max_tokens from the tier" do
      body = Anthropic.body(type(), input(), model: "claude-haiku-5-5", max_tokens: 64)
      refute Map.has_key?(body, :fallbacks)
      assert body.max_tokens == 64
    end
  end

  describe "decide/3" do
    setup do
      name = :"anthropic_#{System.unique_integer([:positive])}"
      {:ok, cfg: [url: "http://api.test", model: "claude-opus-5-5", api_key: "k", plug: {Req.Test, name}], name: name}
    end

    test "a terminal verdict with its cost; what was sent", %{cfg: cfg, name: name} do
      parent = self()

      Req.Test.stub(name, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        send(
          parent,
          {:sent, conn.request_path, Plug.Conn.get_req_header(conn, "x-api-key"),
           Plug.Conn.get_req_header(conn, "anthropic-version"), JSON.decode!(raw)}
        )

        Req.Test.json(conn, %{
          model: "claude-opus-5-5",
          stop_reason: "end_turn",
          content: [%{type: "text", text: ~s({"value": "flaky"})}],
          usage: %{input_tokens: 1_000_000, output_tokens: 0}
        })
      end)

      assert {:ok, result} = Anthropic.decide(type(), input(), cfg)

      assert %{value: :flaky, terminal: true, confidence: nil, probabilities: %{}, model: "anthropic:claude-opus-5-5"} =
               result

      assert_in_delta result.cost.usd, 4.0, 1.0e-6
      assert result.cost.tokens_in == 1_000_000

      assert_received {:sent, "/v1/messages", ["k"], [version], body}
      assert version == Anthropic.version()
      assert body["output_config"]["format"]["type"] == "json_schema"
    end

    test "a refusal is an error, not a verdict", %{cfg: cfg, name: name} do
      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{stop_reason: "refusal", stop_details: %{explanation: "no"}, content: []})
      end)

      assert {:error, {:refusal, "no"}} = Anthropic.decide(type(), input(), cfg)
    end

    test "an answer that is not one of the options is unparseable", %{cfg: cfg, name: name} do
      Req.Test.stub(name, fn conn ->
        Req.Test.json(conn, %{stop_reason: "end_turn", content: [%{type: "text", text: ~s({"value": "maybe"})}]})
      end)

      assert {:error, {:unparseable, ~s({"value": "maybe"})}} = Anthropic.decide(type(), input(), cfg)
    end

    test "a prompt the window cannot hold is a context overflow", %{cfg: cfg, name: name} do
      Req.Test.stub(name, fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: %{message: "prompt is too long: 1000001 tokens"}})
      end)

      assert {:error, {:context_overflow, _}} = Anthropic.decide(type(), input(), cfg)
    end
  end
end
