defmodule Xeito.AllowanceTest do
  use ExUnit.Case, async: true

  alias Xeito.Allowance

  describe "left/2: what the key may still spend" do
    test "the budget that blocks first, as OpenRouter reports it" do
      key = %{"effective_budget" => %{"remaining_usd" => 30}, "limit_remaining" => 99.9}
      assert Allowance.left(key, nil) == 30
    end

    test "without budgets, the key's remaining limit" do
      assert Allowance.left(%{"limit_remaining" => 12.5}, nil) == 12.5
    end

    test "an unlimited key with no budget leaves the account's credits" do
      assert Allowance.left(%{"limit_remaining" => nil}, %{"total_credits" => 30, "total_usage" => 0.5}) == 29.5
    end

    test "the account's credits cap a larger key limit" do
      key = %{"effective_budget" => %{"remaining_usd" => 30}}
      assert Allowance.left(key, %{"total_credits" => 10, "total_usage" => 4}) == 6
    end

    test "nothing known, nothing to cap" do
      assert Allowance.left(%{}, nil) == nil
    end
  end

  describe "price/1: the model's dearest endpoint, its smallest window and longest answer, and price tiers" do
    test "prices per token, context and the longest answer" do
      endpoints = %{
        "endpoints" => [
          %{
            "pricing" => %{"prompt" => "0.000002", "completion" => "0.00001"},
            "context_length" => 1_000_000,
            "max_completion_tokens" => 128_000
          },
          %{
            "pricing" => %{"prompt" => "0.0000022", "completion" => "0.000011"},
            "context_length" => 200_000,
            "max_completion_tokens" => 64_000
          }
        ]
      }

      assert Allowance.price(endpoints) == %{
               prompt: 2.2e-6,
               completion: 1.1e-5,
               context: 200_000,
               output: 64_000,
               tiers: []
             }
    end

    test "dearer rates above a prompt size, the dearest per size across endpoints" do
      tier = fn prompt -> %{"min_prompt_tokens" => 100_000, "prompt" => prompt, "completion" => "0.0000025"} end

      endpoints = %{
        "endpoints" => [
          %{"pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000005", "overrides" => [tier.("0.0000005")]}},
          %{"pricing" => %{"prompt" => "0.0000001", "completion" => "0.0000005", "overrides" => [tier.("0.0000006")]}}
        ]
      }

      assert %{tiers: [%{from: 100_000, prompt: 6.0e-7, completion: 2.5e-6}], output: nil} = Allowance.price(endpoints)
    end

    test "no endpoints, no price" do
      assert Allowance.price(%{"endpoints" => []}) == nil
    end
  end

  describe "worst_case/3: every input token uncached, at its tier's rate, and the answer at its limit" do
    test "the base rate below every tier" do
      assert_in_delta Allowance.worst_case(%{prompt: 2.0e-6, completion: 1.0e-5, tiers: []}, 10_000, 1000), 0.03, 1.0e-9
      assert Allowance.worst_case(nil, 10_000, 1000) == 0.0
    end

    test "the rate of the highest tier the prompt reaches" do
      price = %{
        prompt: 1.0e-7,
        completion: 5.0e-7,
        tiers: [
          %{from: 100_000, prompt: 5.0e-7, completion: 2.5e-6},
          %{from: 500_000, prompt: 1.0e-6, completion: 5.0e-6}
        ]
      }

      assert_in_delta Allowance.worst_case(price, 99_999, 0), 99_999 * 1.0e-7, 1.0e-9
      assert_in_delta Allowance.worst_case(price, 100_000, 1000), 100_000 * 5.0e-7 + 1000 * 2.5e-6, 1.0e-9
      assert_in_delta Allowance.worst_case(price, 600_000, 0), 600_000 * 1.0e-6, 1.0e-9
    end
  end

  describe "verdict/1" do
    test "a call goes ahead while the run's budget and the allowance both hold" do
      assert Allowance.verdict(%{run_spent: 0.1, run_max: 0.5, left: 10.0, worst: 0.2}) == :ok
      assert Allowance.verdict(%{run_spent: 0.1, run_max: 0.5, left: nil, worst: 0.2}) == :ok
    end

    test "the run's budget, once spent, stops the turn" do
      assert {:error, {:budget, text}} = Allowance.verdict(%{run_spent: 0.5, run_max: 0.5, left: 10.0, worst: 0.01})
      assert text =~ "$0.50"
      assert text =~ "/budget"
    end

    test "a call whose worst case does not fit in the allowance is not made" do
      assert {:error, {:allowance, text}} = Allowance.verdict(%{run_spent: 0.0, run_max: 5.0, left: 0.1, worst: 0.2})
      assert text =~ "$0.10 left"
      assert text =~ "$0.20"
      assert Allowance.verdict(%{run_spent: 0.0, run_max: 5.0, left: 0.2, worst: 0.2}) == :ok
    end
  end

  describe "the cache" do
    setup do
      name = :"allow_#{System.unique_integer([:positive])}"
      parent = self()

      Req.Test.stub(name, fn conn ->
        send(parent, {:get, conn.request_path})

        body =
          case conn.request_path do
            "/api/v1/key" -> %{data: %{limit_remaining: 5.0}}
            "/api/v1/credits" -> %{data: %{total_credits: 30, total_usage: 0}}
            "/api/v1/models/m/x/endpoints" -> %{data: %{endpoints: [%{pricing: %{prompt: "1", completion: "2"}}]}}
          end

        Req.Test.json(conn, body)
      end)

      cfg = [url: "http://#{name}.test/api", model: "m/x", api_key: "#{name}", plug: {Req.Test, name}]
      {:ok, cfg: cfg}
    end

    test "the allowance is fetched once, then lowered by what is spent", %{cfg: cfg} do
      assert Allowance.remaining(cfg) == 5.0
      assert_received {:get, "/api/v1/key"}
      assert_received {:get, "/api/v1/credits"}

      Allowance.spent(cfg, 1.5)
      assert Allowance.remaining(cfg) == 3.5
      refute_received {:get, _}
      assert Allowance.last(cfg) == 3.5
    end

    test "spending recorded before the first fetch does not pass for a fetched allowance", %{cfg: cfg} do
      Allowance.spent(cfg, 1.0)
      assert Allowance.last(cfg) == nil
      assert Allowance.remaining(cfg) == 5.0
      assert_received {:get, "/api/v1/key"}
    end

    test "a fetched allowance is used for a minute, then asked for again" do
      s = %{keys: %{k: %{at: 0, left: 5.0, spent: 1.0}}, prices: %{}}
      assert {:reply, {:ok, 4.0}, ^s} = Allowance.handle_call({:remaining, :k, 59_999}, self(), s)
      assert {:reply, :stale, ^s} = Allowance.handle_call({:remaining, :k, 60_000}, self(), s)
      assert {:reply, :stale, ^s} = Allowance.handle_call({:remaining, :other, 0}, self(), s)
    end

    test "a model's price is fetched once", %{cfg: cfg} do
      assert %{prompt: 1.0, completion: 2.0} = Allowance.model_price(cfg)
      assert %{prompt: 1.0} = Allowance.model_price(cfg)
      assert_received {:get, "/api/v1/models/m/x/endpoints"}
      refute_received {:get, _}
    end

    test "when OpenRouter cannot be asked, the allowance is unknown", %{cfg: cfg} do
      cfg = Keyword.merge(cfg, api_key: "down", plug: &Req.Test.transport_error(&1, :econnrefused))
      assert Allowance.remaining(cfg) == nil
      assert Allowance.model_price(cfg) == nil
      assert Allowance.last(cfg) == nil
    end
  end
end
