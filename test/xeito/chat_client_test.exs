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
end
