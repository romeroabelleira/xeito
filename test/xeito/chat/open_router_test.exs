defmodule Xeito.Chat.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Xeito.Chat.OpenRouter

  describe "body/3" do
    test "streams, asks for the usage, keeps prompts private and stops at max_tokens" do
      body = OpenRouter.body([%{role: "user", content: "hi"}], [%{type: "function"}], model: "m/x")

      assert body.model == "m/x"
      assert body.stream == true
      assert body.tools == [%{type: "function"}]
      assert body.max_tokens == 8192
      refute Map.has_key?(body, :temperature)
      assert body.usage == %{include: true}
      assert body.provider == %{require_parameters: true, data_collection: "deny", zdr: true}
      refute Map.has_key?(body, :cache_control)
      refute Map.has_key?(body, :reasoning)
    end

    test "no tools, no tools key; settings from the tier" do
      body =
        OpenRouter.body([], [],
          model: "m/x",
          max_tokens: 100,
          temperature: 0.0,
          zdr: false,
          providers: ["A"],
          reasoning: "low"
        )

      refute Map.has_key?(body, :tools)
      assert body.max_tokens == 100
      assert body.temperature == 0.0
      assert body.provider == %{require_parameters: true, data_collection: "deny", zdr: false, only: ["A"]}
      assert body.reasoning == %{effort: "low"}
    end

    test "an answer format is a strict JSON Schema; thinking on or off, unless an effort is set" do
      schema = %{"type" => "object"}

      assert OpenRouter.body([], [], model: "m/x", format: schema).response_format ==
               %{type: "json_schema", json_schema: %{name: "answer", strict: true, schema: schema}}

      assert OpenRouter.body([], [], model: "m/x", think: true).reasoning == %{enabled: true}
      assert OpenRouter.body([], [], model: "m/x", think: false).reasoning == %{enabled: false}
      assert OpenRouter.body([], [], model: "m/x", think: false, reasoning: "low").reasoning == %{effort: "low"}
      refute Map.has_key?(OpenRouter.body([], [], model: "m/x"), :response_format)
    end

    test "Anthropic models cache the conversation's prefix" do
      assert OpenRouter.body([], [], model: "anthropic/claude-x").cache_control == %{type: "ephemeral"}
    end
  end

  describe "complete/4" do
    setup do
      name = :"or_#{System.unique_integer([:positive])}"
      parent = self()
      sleep = fn ms -> send(parent, {:slept, ms}) end

      {:ok,
       cfg: [url: "http://or.test/api", model: "m/x", api_key: "k", plug: {Req.Test, name}, sleep: sleep], name: name}
    end

    test "a streamed answer with its cost; what was sent", %{cfg: cfg, name: name} do
      parent = self()

      Req.Test.stub(name, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:sent, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"), JSON.decode!(raw)})

        body =
          Enum.map_join(
            [
              %{choices: [%{delta: %{content: "hi"}}]},
              %{model: "m/x", provider: "P", choices: [], usage: %{prompt_tokens: 3, completion_tokens: 1, cost: 0.5}}
            ],
            &("data: " <> JSON.encode!(&1) <> "\n\n")
          )

        conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, body)
      end)

      assert {:ok, %{content: "hi", usd: 0.5, model: "m/x", latency_ms: ms}} =
               OpenRouter.complete([%{role: "user", content: "q"}], [], cfg, fn _ -> :ok end)

      assert ms >= 0
      assert_received {:sent, "/api/v1/chat/completions", ["Bearer k"], %{"model" => "m/x", "stream" => true}}
    end

    test "an HTTP error is returned with its body", %{cfg: cfg, name: name} do
      Req.Test.stub(name, fn conn -> Plug.Conn.send_resp(conn, 400, ~s({"error":{"message":"bad"}})) end)
      assert {:error, {:http, 400, ~s({"error":{"message":"bad"}})}} = OpenRouter.complete([], [], cfg, fn _ -> :ok end)
    end

    test "a rate limit is waited out and tried again, as the server asks", %{cfg: cfg, name: name} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(name, fn conn ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
          conn |> Plug.Conn.put_resp_header("retry-after", "3") |> Plug.Conn.send_resp(429, "rate limited")
        else
          body = "data: " <> JSON.encode!(%{choices: [%{delta: %{content: "ok"}}]}) <> "\n\n"
          conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, body)
        end
      end)

      assert {:ok, %{content: "ok"}} = OpenRouter.complete([], [], cfg, fn _ -> :ok end)
      assert_received {:slept, 3_000}
    end

    test "a quota refusal is not retried, and says what to do", %{cfg: cfg, name: name} do
      Req.Test.stub(name, &Plug.Conn.send_resp(&1, 402, ~s({"error":{"message":"This request requires more credits"}})))
      assert {:error, {:quota, text}} = OpenRouter.complete([], [], cfg, fn _ -> :ok end)
      assert text =~ "add credit"
      refute_received {:slept, _}
    end

    test "a request too long for the model is an overflow", %{cfg: cfg, name: name} do
      Req.Test.stub(name, &Plug.Conn.send_resp(&1, 400, "This endpoint's maximum context length is 131072 tokens"))
      assert {:error, {:context_overflow, _}} = OpenRouter.complete([], [], cfg, fn _ -> :ok end)
    end

    test "so is a stream that stops for length before writing anything", %{cfg: cfg, name: name} do
      Req.Test.stub(name, fn conn ->
        body = "data: " <> JSON.encode!(%{choices: [%{delta: %{}, finish_reason: "length"}]}) <> "\n\n"
        conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, body)
      end)

      assert {:error, {:context_overflow, _}} = OpenRouter.complete([], [], cfg, fn _ -> :ok end)
    end

    test "a transport error is retried, then returned", %{cfg: cfg, name: name} do
      Req.Test.stub(name, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %Req.TransportError{reason: :econnrefused}} = OpenRouter.complete([], [], cfg, fn _ -> :ok end)
      assert_received {:slept, 1_000}
      assert_received {:slept, 2_000}
    end
  end
end
