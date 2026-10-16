defmodule Xeito.Chat.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Xeito.Chat.OpenRouter
  alias Xeito.Chat.OpenRouter.Stream

  describe "messages/1: Xeito's conversation in OpenAI's form" do
    test "tool calls get ids, and their results answer them in order" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "hi", ref: "e1"},
        %{
          role: "assistant",
          content: "",
          tool_calls: [
            %{function: %{name: "read", arguments: %{"path" => "a"}}},
            %{function: %{name: "bash", arguments: %{"command" => "ls"}}}
          ]
        },
        %{role: "tool", tool_name: "read", content: "A", ref: "e2", about: "read of a"},
        %{role: "tool", tool_name: "bash", content: "B"},
        %{role: "assistant", content: "done"}
      ]

      assert OpenRouter.messages(messages) == [
               %{role: "system", content: "sys"},
               %{role: "user", content: "hi"},
               %{
                 role: "assistant",
                 content: nil,
                 tool_calls: [
                   %{id: "call_3_1", type: "function", function: %{name: "read", arguments: ~s({"path":"a"})}},
                   %{id: "call_3_2", type: "function", function: %{name: "bash", arguments: ~s({"command":"ls"})}}
                 ]
               },
               %{role: "tool", tool_call_id: "call_3_1", content: "A"},
               %{role: "tool", tool_call_id: "call_3_2", content: "B"},
               %{role: "assistant", content: "done"}
             ]
    end

    test "a call left without a result is answered before the conversation goes on" do
      messages = [
        %{role: "assistant", content: "let me look", tool_calls: [%{function: %{name: "read", arguments: %{}}}]},
        %{role: "user", content: "stop"}
      ]

      assert [
               %{role: "assistant", content: "let me look", tool_calls: [%{id: "call_1_1"}]},
               %{role: "tool", tool_call_id: "call_1_1", content: "(no result: the call was not run)"},
               %{role: "user", content: "stop"}
             ] = OpenRouter.messages(messages)
    end

    test "unanswered calls at the end are answered too" do
      messages = [%{role: "assistant", content: "", tool_calls: [%{function: %{name: "read", arguments: %{}}}]}]

      assert [_, %{role: "tool", tool_call_id: "call_1_1"}] = OpenRouter.messages(messages)
    end

    test "a result whose call was dropped becomes a note from the user" do
      assert OpenRouter.messages([%{role: "tool", tool_name: "bash", content: "out"}]) ==
               [%{role: "user", content: "[bash result]\nout"}]
    end
  end

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

    test "Anthropic models cache the conversation's prefix" do
      assert OpenRouter.body([], [], model: "anthropic/claude-x").cache_control == %{type: "ephemeral"}
    end
  end

  describe "Stream: OpenAI's server-sent events" do
    defp feed(chunks, on_delta \\ fn _ -> :ok end) do
      chunks |> Enum.reduce(Stream.new(), &Stream.feed(&2, &1, on_delta)) |> Stream.finish()
    end

    defp event(map), do: "data: " <> JSON.encode!(map) <> "\n\n"

    test "text arrives in pieces, possibly split mid-line, and is passed on as it comes" do
      parent = self()
      data = event(%{choices: [%{delta: %{content: "Hel"}}]}) <> event(%{choices: [%{delta: %{content: "lo"}}]})
      {a, b} = String.split_at(data, 20)

      assert {:ok, %{content: "Hello", tool_calls: []}} =
               feed([": OPENROUTER PROCESSING\n\n", a, b, "data: [DONE]\n\n"], &send(parent, {:delta, &1}))

      assert_received {:delta, "Hel"}
      assert_received {:delta, "lo"}
    end

    test "tool calls are assembled from fragments by index" do
      chunks = [
        event(%{
          choices: [%{delta: %{tool_calls: [%{index: 0, id: "x", function: %{name: "read", arguments: ~s({"pa)}}]}}]
        }),
        event(%{choices: [%{delta: %{tool_calls: [%{index: 0, function: %{arguments: ~s(th":"a"})}}]}}]}),
        event(%{choices: [%{delta: %{tool_calls: [%{index: 1, function: %{name: "bash", arguments: ""}}]}}]})
      ]

      assert {:ok, %{tool_calls: [%{name: "read", arguments: %{"path" => "a"}}, %{name: "bash", arguments: %{}}]}} =
               feed(chunks)
    end

    test "arguments that are not JSON are kept raw" do
      chunks = [event(%{choices: [%{delta: %{tool_calls: [%{index: 0, function: %{name: "r", arguments: "{"}}]}}]})]
      assert {:ok, %{tool_calls: [%{arguments: %{"_raw" => "{"}}]}} = feed(chunks)
    end

    test "the last event carries the usage: tokens, cache reads and the cost" do
      usage = %{prompt_tokens: 100, completion_tokens: 7, cost: 0.0123, prompt_tokens_details: %{cached_tokens: 80}}
      chunks = [event(%{model: "m/x", provider: "P", choices: [%{delta: %{}}], usage: usage})]

      assert {:ok, %{tokens_in: 100, tokens_out: 7, cached_tokens: 80, usd: 0.0123, served_by: "openrouter:m/x@P"}} =
               feed(chunks)
    end

    test "without usage, counts are zero" do
      assert {:ok, %{tokens_in: 0, tokens_out: 0, cached_tokens: 0, usd: usd, served_by: nil}} = feed([])
      assert usd == 0.0
    end

    test "an error event ends the answer with that error" do
      assert {:error, {:openrouter, %{"message" => "no"}}} =
               feed([event(%{choices: [%{delta: %{content: "a"}}]}), event(%{error: %{message: "no"}})])
    end

    test "a line that is not JSON is skipped" do
      assert {:ok, %{content: "a"}} = feed(["data: {oops\n\n", event(%{choices: [%{delta: %{content: "a"}}]})])
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

      assert is_integer(ms)
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
