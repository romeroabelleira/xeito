defmodule Xeito.Chat.OpenAITest do
  use ExUnit.Case, async: true

  alias Xeito.Chat.OpenAI
  alias Xeito.Chat.OpenAI.Stream

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

      assert OpenAI.messages(messages) == [
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
             ] = OpenAI.messages(messages)
    end

    test "unanswered calls at the end are answered too" do
      messages = [%{role: "assistant", content: "", tool_calls: [%{function: %{name: "read", arguments: %{}}}]}]

      assert [_, %{role: "tool", tool_call_id: "call_1_1"}] = OpenAI.messages(messages)
    end

    test "a result whose call was dropped becomes a note from the user" do
      assert OpenAI.messages([%{role: "tool", tool_name: "bash", content: "out"}]) ==
               [%{role: "user", content: "[bash result]\nout"}]
    end
  end

  describe "body/3: what every compatible server takes" do
    test "the model, the messages and a stream with usage; tools only when there are any" do
      assert OpenAI.body([%{role: "user", content: "hi", ref: "e1"}], [], model: "m") == %{
               model: "m",
               messages: [%{role: "user", content: "hi"}],
               stream: true,
               stream_options: %{include_usage: true}
             }

      assert OpenAI.body([], [%{type: "function"}], model: "m").tools == [%{type: "function"}]
    end

    test "an answer limit, a temperature and an answer format only when the tier sets them" do
      schema = %{type: "object"}
      body = OpenAI.body([], [], model: "m", max_tokens: 256, temperature: 0, format: schema)

      assert %{max_tokens: 256, temperature: 0} = body
      assert body.response_format == %{type: "json_schema", json_schema: %{name: "answer", strict: true, schema: schema}}
    end

    test "a tier without a model cannot ask" do
      assert_raise KeyError, fn -> OpenAI.body([], [], []) end
    end
  end

  describe "Stream: OpenAI's server-sent events" do
    defp feed(chunks, on_delta \\ fn _ -> :ok end) do
      chunks |> Enum.reduce(Stream.new(:openai), &Stream.feed(&2, &1, on_delta)) |> Stream.finish()
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

      assert {:ok, %{tokens_in: 100, tokens_out: 7, cached_tokens: 80, usd: 0.0123, served_by: "openai:m/x@P"}} =
               feed(chunks)
    end

    test "without usage, counts are zero" do
      assert {:ok, %{tokens_in: 0, tokens_out: 0, cached_tokens: 0, usd: usd, served_by: nil}} = feed([])
      assert usd == 0.0
    end

    test "an error event ends the answer with that error" do
      assert {:error, {:openai, %{"message" => "no"}}} =
               feed([event(%{choices: [%{delta: %{content: "a"}}]}), event(%{error: %{message: "no"}})])
    end

    test "a line that is not JSON is skipped" do
      assert {:ok, %{content: "a"}} = feed(["data: {oops\n\n", event(%{choices: [%{delta: %{content: "a"}}]})])
    end
  end

  describe "complete/4 and request/4" do
    defp sse(events), do: Enum.map_join(events, &("data: " <> JSON.encode!(&1) <> "\n\n"))

    defp stream(conn, events),
      do: conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, sse(events))

    defp cfg(stub, extra \\ []), do: [url: "http://openai.test", model: "m", plug: {Req.Test, stub}] ++ extra

    test "a streamed answer: its text as it arrives, its tokens, and who served it" do
      Req.Test.stub(:oa_chat, fn conn ->
        send(self(), {:path, conn.request_path, Plug.Conn.get_req_header(conn, "x-extra")})

        stream(conn, [
          %{choices: [%{delta: %{content: "he"}}]},
          %{choices: [%{delta: %{content: "llo"}, finish_reason: "stop"}]},
          %{choices: [], usage: %{prompt_tokens: 12, completion_tokens: 2, prompt_tokens_details: %{cached_tokens: 8}}}
        ])
      end)

      parent = self()

      assert {:ok, reply} =
               OpenAI.complete([%{role: "user", content: "q"}], [], cfg(:oa_chat), &send(parent, {:delta, &1}))

      assert %{content: "hello", tool_calls: [], model: "m", served_by: "openai:m", first_token_ms: nil} = reply
      assert %{tokens_in: 12, tokens_out: 2, cached_tokens: 8, usd: +0.0, finish_reason: "stop"} = reply
      assert reply.latency_ms >= 0
      assert_received {:delta, "he"}
      assert_received {:delta, "llo"}
      assert_received {:path, "/v1/chat/completions", []}
    end

    test "a backend's name labels who served and its headers are sent" do
      Req.Test.stub(:oa_wire, fn conn ->
        send(self(), {:extra, Plug.Conn.get_req_header(conn, "x-extra")})
        stream(conn, [%{model: "actual", provider: "P", choices: [%{delta: %{content: "x"}}]}])
      end)

      body = OpenAI.body([], [], model: "m")
      wire = [name: :elsewhere, headers: [{"x-extra", "1"}]]

      assert {:ok, %{served_by: "elsewhere:actual@P", model: "m"}} =
               OpenAI.request(body, cfg(:oa_wire), fn _ -> :ok end, wire)

      assert_received {:extra, ["1"]}
    end

    test "an error in the stream carries the backend's name; a refused request its status and body" do
      Req.Test.stub(:oa_error, &stream(&1, [%{error: %{message: "engine_error"}}]))

      assert OpenAI.complete([], [], cfg(:oa_error), fn _ -> :ok end) ==
               {:error, {:openai, %{"message" => "engine_error"}}}

      Req.Test.stub(:oa_400, &Plug.Conn.send_resp(&1, 400, ~s({"error":"bad"})))
      assert OpenAI.complete([], [], cfg(:oa_400), fn _ -> :ok end) == {:error, {:http, 400, ~s({"error":"bad"})}}
    end

    test "a busy server is tried again; an answer cut before it began is an overflow" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(:oa_busy, fn conn ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0,
          do: Plug.Conn.send_resp(conn, 503, "loading"),
          else: stream(conn, [%{choices: [%{delta: %{content: "ok"}}]}])
      end)

      parent = self()

      assert {:ok, %{content: "ok"}} =
               OpenAI.complete([], [], cfg(:oa_busy, sleep: &send(parent, {:slept, &1})), fn _ -> :ok end)

      assert_received {:slept, _ms}
      assert Agent.get(calls, & &1) == 2

      Req.Test.stub(:oa_length, &stream(&1, [%{choices: [%{delta: %{}, finish_reason: "length"}]}]))
      assert {:error, {:context_overflow, _}} = OpenAI.complete([], [], cfg(:oa_length), fn _ -> :ok end)
    end
  end
end
