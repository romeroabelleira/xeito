defmodule Xeito.ChatClientTest do
  # Chat calls run through the large tier's shared queue, so the stub is shared (serial).
  use ExUnit.Case, async: false

  alias Xeito.Chat

  setup {Req.Test, :set_req_test_to_shared}

  # A streamed answer (NDJSON) whose one message carries `calls`.
  defp answering(calls) do
    Req.Test.stub(:chat_client, fn conn ->
      lines = [
        %{"message" => %{"role" => "assistant", "content" => "", "tool_calls" => calls}, "done" => false},
        %{
          "message" => %{"role" => "assistant", "content" => ""},
          "done" => true,
          "prompt_eval_count" => 5,
          "eval_count" => 1
        }
      ]

      conn
      |> Plug.Conn.put_resp_content_type("application/x-ndjson")
      |> Plug.Conn.send_resp(200, Enum.map_join(lines, "\n", &JSON.encode!/1))
    end)

    [url: "http://chat.test", plug: {Req.Test, :chat_client}, model: "big"]
  end

  defp call(arguments), do: %{"function" => %{"name" => "read", "arguments" => arguments}}

  test "tool-call arguments: an object, a JSON string, anything else kept raw, or none" do
    calls = [call(%{"path" => "a"}), call(~s({"path": "b"})), call("not json"), call(nil)]
    assert {:ok, %{tool_calls: tool_calls}} = Chat.complete([%{role: "user", content: "hi"}], [], answering(calls))

    assert Enum.map(tool_calls, & &1.arguments) == [%{"path" => "a"}, %{"path" => "b"}, %{"_raw" => "not json"}, %{}]
  end

  test "without a configured chat model there is no chat" do
    assert Chat.complete([%{role: "user", content: "hi"}], [], []) == {:error, :chat_model_unavailable}
  end

  describe "a remote chat tier (OpenRouter)" do
    setup do
      name = :"remote_chat_#{System.unique_integer([:positive])}"
      parent = self()

      Req.Test.stub(name, fn conn ->
        case conn.request_path do
          "/api/v1/key" ->
            Req.Test.json(conn, %{data: %{limit_remaining: Process.get(:left, 10.0)}})

          "/api/v1/credits" ->
            Plug.Conn.send_resp(conn, 403, "management key required")

          "/api/v1/models/m/chat/endpoints" ->
            Req.Test.json(conn, %{data: %{endpoints: [%{pricing: %{prompt: "0.000002", completion: "0.00001"}}]}})

          "/api/v1/chat/completions" ->
            send(parent, :asked)

            body =
              "data: " <>
                JSON.encode!(%{model: "m/chat", choices: [%{delta: %{content: "ok"}}], usage: %{cost: 0.25}}) <> "\n\n"

            conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, body)
        end
      end)

      run = "chat-run-#{name}"
      on_exit(fn -> Xeito.Budget.delete(run) end)

      {:ok,
       run: run,
       opts: [
         tier: :remote_frontier,
         url: "http://or.test/api",
         model: "m/chat",
         api_key: "#{name}",
         plug: {Req.Test, name},
         run: run,
         max_usd: 1.0
       ]}
    end

    test "answers through OpenRouter, and its cost is charged to the run and the key", %{opts: opts, run: run} do
      assert {:ok, %{content: "ok", usd: 0.25, tier: :remote_frontier}} =
               Chat.complete([%{role: "user", content: "hi"}], [], opts)

      assert Xeito.Budget.get(run, :usd) == 0.25
      assert Xeito.Allowance.last(opts) == 9.75
    end

    test "once the run's budget is spent, no call is made", %{opts: opts, run: run} do
      Xeito.Budget.add(run, :usd, 1.0)
      assert {:error, {:budget, _}} = Chat.complete([%{role: "user", content: "hi"}], [], opts)
      refute_received :asked
    end

    test "a call the allowance could not pay for at worst is not made", %{opts: opts} do
      # Worst case: 8192 answer tokens at $0.00001 is about $0.08.
      Xeito.Allowance.spent(opts, 0.0)
      Xeito.Allowance.remaining(opts)
      Xeito.Allowance.spent(opts, 9.95)
      assert {:error, {:allowance, _}} = Chat.complete([%{role: "user", content: "hi"}], [], opts)
      refute_received :asked
    end

    test "a tier whose backend cannot chat is an error" do
      assert Chat.complete([], [], tier: :local_decision, url: "http://x.test") ==
               {:error, {:no_chat_backend, :system_one}}
    end
  end

  test "the chat tier: the session's, else the configured one, else local" do
    assert Chat.tier(tier: :remote) == :remote
    assert Chat.tier([]) == :local

    Application.put_env(:xeito, :chat_tier, :remote_frontier)
    on_exit(fn -> Application.delete_env(:xeito, :chat_tier) end)
    assert Chat.tier([]) == :remote_frontier
  end
end
