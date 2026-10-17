defmodule Xeito.Tiers.ModelsCheckTest do
  use ExUnit.Case, async: true

  alias Xeito.Tiers.ModelsCheck

  # OpenRouter's /models/user entry and models.dev's entry for the same model.
  @openrouter %{
    "id" => "anthropic/claude-x",
    "context_length" => 1_000_000,
    "top_provider" => %{"context_length" => 1_000_000, "max_completion_tokens" => 128_000},
    "pricing" => %{"prompt" => "0.000002", "completion" => "0.00001"},
    "supported_parameters" => ~w(max_tokens reasoning tools)
  }
  @models_dev %{
    "id" => "anthropic/claude-x",
    "limit" => %{"context" => 1_000_000, "output" => 128_000},
    "cost" => %{"input" => 2, "output" => 10},
    "temperature" => false,
    "tool_call" => true,
    "reasoning" => true
  }

  describe "compare/3" do
    test "the same model in both: each field side by side, nothing different" do
      check = ModelsCheck.compare(@openrouter, @models_dev, [])

      assert check.rows == [
               {"context", 1_000_000, 1_000_000},
               {"longest answer", 128_000, 128_000},
               {"input $/M", 2.0, 2.0},
               {"output $/M", 10.0, 10.0},
               {"temperature", false, false},
               {"tools", true, true}
             ]

      assert check.differences == []
      assert check.warnings == []
    end

    test "fields that differ are named" do
      dev = @models_dev |> put_in(["cost", "input"], 2.2) |> put_in(["limit", "context"], 200_000)
      assert ModelsCheck.compare(@openrouter, dev, []).differences == ["context", "input $/M"]
    end

    test "tier settings the model does not take are warned about" do
      check = ModelsCheck.compare(@openrouter, @models_dev, temperature: 0.2, reasoning: "high")
      assert check.warnings == ["the tier sets a temperature, which this model does not take"]

      plain = Map.put(@openrouter, "supported_parameters", ~w(max_tokens tools temperature))

      assert ModelsCheck.compare(plain, @models_dev, reasoning: "high").warnings == [
               "the tier sets a reasoning effort, which this model does not take"
             ]
    end

    test "a model missing from either side is reported, with what the other says" do
      assert %{missing: "models.dev", rows: [{"context", 1_000_000, nil} | _]} = ModelsCheck.compare(@openrouter, nil, [])
      assert %{missing: "OpenRouter for this key"} = ModelsCheck.compare(nil, @models_dev, [])
    end
  end

  test "format/1: a block per tier, differences marked, then warnings" do
    same =
      @openrouter
      |> ModelsCheck.compare(@models_dev, temperature: 0.2)
      |> Map.merge(%{tier: :remote_frontier, model: "anthropic/claude-x"})

    text = ModelsCheck.format([same])

    assert text =~ "remote_frontier · anthropic/claude-x"
    assert text =~ ~r/context\s+1000000\s+1000000/
    assert text =~ "no differences"
    assert text =~ "! the tier sets a temperature"

    dev = put_in(@models_dev, ["limit", "output"], 64_000)
    differs = @openrouter |> ModelsCheck.compare(dev, []) |> Map.merge(%{tier: :remote, model: "m"})
    assert ModelsCheck.format([differs]) =~ ~r/≠ longest answer\s+128000\s+64000/
  end

  describe "fetching" do
    setup do
      name = :"models_#{System.unique_integer([:positive])}"

      Req.Test.stub(name, fn conn ->
        case conn.request_path do
          "/api/v1/models/user" -> Req.Test.json(conn, %{data: [@openrouter]})
          "/api.json" -> Req.Test.json(conn, %{openrouter: %{models: %{"anthropic/claude-x" => @models_dev}}})
        end
      end)

      {:ok, plug: {Req.Test, name}}
    end

    test "run/2: each remote tier's model from both sources", %{plug: plug} do
      tiers = [remote_frontier: [url: "http://or.test/api", model: "anthropic/claude-x", api_key: "k", plug: plug]]

      assert [%{tier: :remote_frontier, model: "anthropic/claude-x", differences: [], missing: nil}] =
               ModelsCheck.run(tiers, url: "http://dev.test/api.json", plug: plug)
    end

    test "run/2: nothing to check without remote tiers" do
      assert ModelsCheck.run([], url: "http://dev.test/api.json") == []
    end
  end
end
