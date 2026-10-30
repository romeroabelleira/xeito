defmodule Xeito.Chat.AnthropicTest do
  use ExUnit.Case, async: true

  alias Xeito.Chat.Anthropic
  alias Xeito.Chat.Anthropic.Stream

  describe "messages/1: Xeito's conversation in the API's form" do
    test "system text apart; tool calls get ids, and their results answer them in one user message" do
      messages = [
        %{role: "system", content: "sys"},
        %{role: "user", content: "hi", ref: "e1"},
        %{
          role: "assistant",
          content: "looking",
          tool_calls: [
            %{function: %{name: "read", arguments: %{"path" => "a"}}},
            %{function: %{name: "bash", arguments: %{"command" => "ls"}}}
          ]
        },
        %{role: "tool", tool_name: "read", content: "A", ref: "e2", about: "read of a"},
        %{role: "tool", tool_name: "bash", content: ""},
        %{role: "assistant", content: "done"}
      ]

      assert Anthropic.messages(messages) ==
               {"sys",
                [
                  %{role: "user", content: [%{type: "text", text: "hi"}]},
                  %{
                    role: "assistant",
                    content: [
                      %{type: "text", text: "looking"},
                      %{type: "tool_use", id: "toolu_2_1", name: "read", input: %{"path" => "a"}},
                      %{type: "tool_use", id: "toolu_2_2", name: "bash", input: %{"command" => "ls"}}
                    ]
                  },
                  %{
                    role: "user",
                    content: [
                      %{type: "tool_result", tool_use_id: "toolu_2_1", content: "A"},
                      %{type: "tool_result", tool_use_id: "toolu_2_2", content: "(no output)"}
                    ]
                  },
                  %{role: "assistant", content: [%{type: "text", text: "done"}]}
                ]}
    end

    test "two system messages join; a call left without a result is answered before the conversation goes on" do
      messages = [
        %{role: "system", content: "a"},
        %{role: "system", content: "b"},
        %{role: "assistant", content: "", tool_calls: [%{function: %{name: "read", arguments: %{}}}]},
        %{role: "user", content: "stop"}
      ]

      assert {"a\n\nb",
              [
                %{role: "assistant", content: [%{type: "tool_use", id: "toolu_1_1"}]},
                %{
                  role: "user",
                  content: [
                    %{type: "tool_result", tool_use_id: "toolu_1_1", content: "(no result: the call was not run)"},
                    %{type: "text", text: "stop"}
                  ]
                }
              ]} = Anthropic.messages(messages)
    end

    test "unanswered calls at the end are answered too" do
      messages = [%{role: "assistant", content: "", tool_calls: [%{function: %{name: "read", arguments: %{}}}]}]

      assert {"", [_, %{role: "user", content: [%{type: "tool_result", tool_use_id: "toolu_1_1"}]}]} =
               Anthropic.messages(messages)
    end

    test "a result whose call was dropped becomes a note from the user, and an empty assistant message is dropped" do
      messages = [%{role: "assistant", content: ""}, %{role: "tool", tool_name: "bash", content: "out"}]

      assert Anthropic.messages(messages) ==
               {"", [%{role: "user", content: [%{type: "text", text: "[bash result]\nout"}]}]}
    end
  end

  test "tools/1: function specs become the API's tools" do
    spec = %{type: "function", function: %{name: "read", description: "Read", parameters: %{type: "object"}}}
    assert Anthropic.tools([spec]) == [%{name: "read", description: "Read", input_schema: %{type: "object"}}]
  end

  describe "body/3" do
    test "streams, caches the prefix, stops at max_tokens, asks for fallbacks, and sends no temperature" do
      body =
        Anthropic.body([%{role: "system", content: "s"}, %{role: "user", content: "hi"}], [], model: "claude-opus-5-5")

      assert body.model == "claude-opus-5-5"
      assert body.stream == true
      assert body.max_tokens == 8192
      assert body.cache_control == %{type: "ephemeral"}
      assert body.system == "s"
      assert body.messages == [%{role: "user", content: [%{type: "text", text: "hi"}]}]
      assert body.fallbacks == "default"
      refute Map.has_key?(body, :tools)
      refute Map.has_key?(body, :output_config)
      refute Map.has_key?(body, :temperature)
    end

    test "tools, effort and an answer format from the tier; no system key without system text; no fallbacks where the model takes none" do
      spec = %{type: "function", function: %{name: "read", description: "Read", parameters: %{}}}
      schema = %{"type" => "object"}

      body =
        Anthropic.body([%{role: "user", content: "hi"}], [spec],
          model: "claude-haiku-5-5",
          max_tokens: 100,
          reasoning: "low",
          format: schema,
          temperature: 0.5
        )

      assert body.tools == [%{name: "read", description: "Read", input_schema: %{}}]
      assert body.max_tokens == 100
      assert body.output_config == %{effort: "low", format: %{type: "json_schema", schema: schema}}
      refute Map.has_key?(body, :system)
      refute Map.has_key?(body, :fallbacks)
      refute Map.has_key?(body, :temperature)
    end
  end

  describe "Stream: the API's server-sent events" do
    defp feed(events, on_delta \\ fn _ -> :ok end) do
      events |> Enum.reduce(Stream.new(), &Stream.feed(&2, &1, on_delta)) |> Stream.finish()
    end

    defp event(map), do: "event: #{map[:type]}\ndata: " <> JSON.encode!(map) <> "\n\n"

    test "text arrives in pieces, possibly split mid-line, and is passed on as it comes" do
      parent = self()

      data =
        event(%{type: "content_block_start", index: 0, content_block: %{type: "text", text: ""}}) <>
          event(%{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: "Hel"}}) <>
          event(%{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: "lo"}})

      {a, b} = String.split_at(data, 40)

      assert {:ok, %{content: "Hello", tool_calls: []}} =
               feed([~s(event: ping\ndata: {"type": "ping"}\n\n), a, b], &send(parent, {:delta, &1}))

      assert_received {:delta, "Hel"}
      assert_received {:delta, "lo"}
    end

    test "tool calls are assembled from their block and its JSON fragments, by index; thinking is not text" do
      events = [
        event(%{type: "content_block_start", index: 0, content_block: %{type: "thinking", thinking: ""}}),
        event(%{type: "content_block_delta", index: 0, delta: %{type: "thinking_delta", thinking: "hmm"}}),
        event(%{
          type: "content_block_start",
          index: 1,
          content_block: %{type: "tool_use", id: "x", name: "read", input: %{}}
        }),
        event(%{type: "content_block_delta", index: 1, delta: %{type: "input_json_delta", partial_json: ~s({"pa)}}),
        event(%{type: "content_block_delta", index: 1, delta: %{type: "input_json_delta", partial_json: ~s(th":"a"})}}),
        event(%{
          type: "content_block_start",
          index: 2,
          content_block: %{type: "tool_use", id: "y", name: "bash", input: %{}}
        })
      ]

      assert {:ok,
              %{content: "", tool_calls: [%{name: "read", arguments: %{"path" => "a"}}, %{name: "bash", arguments: %{}}]}} =
               feed(events)
    end

    test "arguments that are not JSON are kept raw" do
      events = [
        event(%{
          type: "content_block_start",
          index: 0,
          content_block: %{type: "tool_use", id: "x", name: "r", input: %{}}
        }),
        event(%{type: "content_block_delta", index: 0, delta: %{type: "input_json_delta", partial_json: "{"}})
      ]

      assert {:ok, %{tool_calls: [%{arguments: %{"_raw" => "{"}}]}} = feed(events)
    end

    test "the usage: the prompt's tokens from the start, the answer's and the stop reason from the end; the model, or the fallback that took over" do
      events = [
        event(%{
          type: "message_start",
          message: %{
            model: "claude-opus-5-5",
            usage: %{input_tokens: 100, cache_read_input_tokens: 80, cache_creation_input_tokens: 0}
          }
        }),
        event(%{
          type: "content_block_start",
          index: 0,
          content_block: %{type: "fallback", from: %{model: "claude-opus-5-5"}, to: %{model: "claude-opus-4-8"}}
        }),
        event(%{type: "message_delta", delta: %{stop_reason: "end_turn"}, usage: %{output_tokens: 7}}),
        event(%{type: "message_stop"})
      ]

      assert {:ok, %{usage: usage, model: "claude-opus-4-8", finish_reason: "end_turn"}} = feed(events)

      assert usage == %{
               "input_tokens" => 100,
               "cache_read_input_tokens" => 80,
               "cache_creation_input_tokens" => 0,
               "output_tokens" => 7
             }
    end

    test "without events, nothing is known" do
      assert {:ok, %{content: "", tool_calls: [], usage: %{}, model: nil, finish_reason: nil}} = feed([])
    end

    test "an error event ends the answer with that error" do
      assert {:error, {:anthropic, %{"type" => "overloaded_error"}}} =
               feed([
                 event(%{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: "a"}}),
                 event(%{type: "error", error: %{type: "overloaded_error"}})
               ])
    end

    test "a line that is not JSON is skipped" do
      assert {:ok, %{content: "a"}} =
               feed([
                 "data: {oops\n\n",
                 event(%{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: "a"}})
               ])
    end
  end

  describe "complete/4" do
    setup do
      name = :"anthropic_chat_#{System.unique_integer([:positive])}"
      parent = self()
      sleep = fn ms -> send(parent, {:slept, ms}) end

      {:ok,
       cfg: [url: "http://api.test", model: "claude-opus-5-5", api_key: "k", plug: {Req.Test, name}, sleep: sleep],
       name: name}
    end

    defp sse(events), do: Enum.map_join(events, &("event: #{&1[:type]}\ndata: " <> JSON.encode!(&1) <> "\n\n"))

    defp respond(conn, events) do
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse(events))
    end

    test "a streamed answer with its cost and who served it; what was sent", %{cfg: cfg, name: name} do
      parent = self()

      Req.Test.stub(name, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:sent, conn.request_path, Plug.Conn.get_req_header(conn, "x-api-key"), JSON.decode!(raw)})

        respond(conn, [
          %{
            type: "message_start",
            message: %{model: "claude-opus-5-5", usage: %{input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000}}
          },
          %{type: "content_block_start", index: 0, content_block: %{type: "text", text: ""}},
          %{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: "hi"}},
          %{type: "message_delta", delta: %{stop_reason: "end_turn"}, usage: %{output_tokens: 100_000}}
        ])
      end)

      assert {:ok, reply} = Anthropic.complete([%{role: "user", content: "hello"}], [], cfg, &send(parent, {:delta, &1}))
      assert %{content: "hi", tool_calls: [], model: "claude-opus-5-5", served_by: "anthropic:claude-opus-5-5"} = reply
      assert reply.tokens_in == 2_000_000
      assert reply.tokens_out == 100_000
      assert reply.cached_tokens == 1_000_000
      assert_in_delta reply.usd, 4 + 0.2 + 2, 1.0e-6
      assert_received {:delta, "hi"}
      assert_received {:sent, "/v1/messages", ["k"], %{"stream" => true, "fallbacks" => "default", "max_tokens" => 8192}}
    end

    test "a refusal that comes back despite the fallbacks is an error", %{cfg: cfg, name: name} do
      Req.Test.stub(name, fn conn ->
        respond(conn, [%{type: "message_delta", delta: %{stop_reason: "refusal"}, usage: %{output_tokens: 0}}])
      end)

      assert {:error, {:refusal, _}} = Anthropic.complete([%{role: "user", content: "x"}], [], cfg, fn _ -> :ok end)
    end

    test "a stream that stops for length before any text is a context overflow", %{cfg: cfg, name: name} do
      Req.Test.stub(name, fn conn ->
        respond(conn, [%{type: "message_delta", delta: %{stop_reason: "max_tokens"}, usage: %{output_tokens: 0}}])
      end)

      assert {:error, {:context_overflow, _}} =
               Anthropic.complete([%{role: "user", content: "x"}], [], cfg, fn _ -> :ok end)
    end

    test "a prompt the API refuses as too long is a context overflow", %{cfg: cfg, name: name} do
      Req.Test.stub(name, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{error: %{type: "invalid_request_error", message: "prompt is too long"}})
      end)

      assert {:error, {:context_overflow, _}} =
               Anthropic.complete([%{role: "user", content: "x"}], [], cfg, fn _ -> :ok end)
    end

    test "an overloaded API is retried after the wait it asks for", %{cfg: cfg, name: name} do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(name, fn conn ->
        case Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) do
          1 -> conn |> Plug.Conn.put_resp_header("retry-after", "2") |> Plug.Conn.send_resp(529, "overloaded")
          _ -> respond(conn, [%{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: "ok"}}])
        end
      end)

      assert {:ok, %{content: "ok"}} = Anthropic.complete([%{role: "user", content: "x"}], [], cfg, fn _ -> :ok end)
      assert_received {:slept, 2_000}
    end
  end
end
