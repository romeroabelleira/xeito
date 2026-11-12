defmodule Xeito.Backends.OpenAITest do
  use ExUnit.Case, async: true

  alias Xeito.Backends.OpenAI
  alias Xeito.Decision
  alias Xeito.Decisions.Triage

  @input %{test: "CheckoutTest", output: "left: 107.0 right: 108.0", diff_stat: "lib/pricing.ex"}

  defp type, do: Decision.type!(Triage)
  defp cfg(stub, extra \\ []), do: [url: "http://openai.test", model: "served-model", plug: {Req.Test, stub}] ++ extra

  # The value's first token with its alternatives, as OpenAI reports them.
  defp logprobs do
    [
      %{"token" => "{\"", "logprob" => 0.0},
      %{"token" => "value", "logprob" => 0.0},
      %{"token" => "\":", "logprob" => 0.0},
      %{"token" => " \"", "logprob" => 0.0},
      %{
        "token" => "code",
        "logprob" => :math.log(0.8),
        "top_logprobs" => [
          %{"token" => "code", "logprob" => :math.log(0.8)},
          %{"token" => "test", "logprob" => :math.log(0.2)}
        ]
      },
      %{"token" => "_bug", "logprob" => 0.0},
      %{"token" => "\"}", "logprob" => 0.0}
    ]
  end

  describe "body/3: the decision request" do
    test "the schema, temperature 0 and logprobs; nothing a plain server would refuse" do
      body = OpenAI.body(type(), @input, model: "served-model")

      assert body |> Map.keys() |> Enum.sort() == [
               :logprobs,
               :max_tokens,
               :messages,
               :model,
               :response_format,
               :temperature,
               :top_logprobs
             ]

      assert %{model: "served-model", temperature: 0, max_tokens: 64, logprobs: true, top_logprobs: 20} = body
      assert %{type: "json_schema", json_schema: %{name: "triage", strict: true, schema: %{}}} = body.response_format
    end

    test "the alternatives asked for are capped at 20; logprobs can be left out" do
      assert OpenAI.body(type(), @input, model: "m", top_logprobs: 5).top_logprobs == 5
      assert OpenAI.body(type(), @input, model: "m", top_logprobs: 50).top_logprobs == 20
      assert OpenAI.body(type(), @input, model: "m", max_tokens: 8).max_tokens == 8

      plain = OpenAI.body(type(), @input, model: "m", logprobs: false)
      refute Map.has_key?(plain, :logprobs)
      refute Map.has_key?(plain, :top_logprobs)
    end
  end

  describe "decide/3" do
    test "confidence from the logprobs at the value; the key is sent when there is one" do
      Req.Test.stub(:openai_decide, fn conn ->
        send(self(), {:asked, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})

        Req.Test.json(conn, %{
          "choices" => [
            %{"message" => %{"content" => ~s({"value": "code_bug"})}, "logprobs" => %{"content" => logprobs()}}
          ],
          "usage" => %{"prompt_tokens" => 200, "completion_tokens" => 6}
        })
      end)

      assert {:ok,
              %{value: :code_bug, confidence: c, probabilities: probs, model: "openai:served-model", cost: cost} = result} =
               OpenAI.decide(type(), @input, cfg(:openai_decide, api_key: "k"))

      assert_in_delta c, 0.8, 1.0e-9
      assert_in_delta probs[:test_bug], 0.2, 1.0e-9
      refute Map.has_key?(result, :terminal)
      assert cost == %{tokens_in: 200, tokens_out: 6, usd: 0.0}
      assert_received {:asked, "/v1/chat/completions", ["Bearer k"]}

      assert {:ok, _} = OpenAI.decide(type(), @input, cfg(:openai_decide))
      assert_received {:asked, "/v1/chat/completions", []}
    end

    test "a server without logprobs gives a terminal answer, named by the model it reports" do
      Req.Test.stub(:openai_plain, fn conn ->
        Req.Test.json(conn, %{"model" => "actual", "choices" => [%{"message" => %{"content" => ~s({"value": "flaky"})}}]})
      end)

      assert {:ok,
              %{value: :flaky, confidence: nil, terminal: true, probabilities: %{}, model: "openai:actual", cost: cost}} =
               OpenAI.decide(type(), @input, cfg(:openai_plain))

      assert cost == %{tokens_in: 0, tokens_out: 0, usd: 0.0}
    end

    test "a refusal, an answer outside the options, an error body and a failed request are errors" do
      reply = fn stub, body -> Req.Test.stub(stub, &Req.Test.json(&1, body)) end

      reply.(:openai_refusal, %{"choices" => [%{"message" => %{"content" => nil, "refusal" => "no"}}]})
      assert OpenAI.decide(type(), @input, cfg(:openai_refusal)) == {:error, {:refusal, "no"}}

      reply.(:openai_unknown, %{"choices" => [%{"message" => %{"content" => ~s({"value": "shrug"})}}]})
      assert OpenAI.decide(type(), @input, cfg(:openai_unknown)) == {:error, {:unparseable, ~s({"value": "shrug"})}}

      reply.(:openai_prose, %{"choices" => [%{"message" => %{"content" => "It is flaky."}}]})
      assert OpenAI.decide(type(), @input, cfg(:openai_prose)) == {:error, {:unparseable, "It is flaky."}}

      reply.(:openai_error, %{"error" => %{"message" => "overloaded"}})
      assert OpenAI.decide(type(), @input, cfg(:openai_error)) == {:error, {:openai, %{"message" => "overloaded"}}}

      Req.Test.stub(:openai_400, &Plug.Conn.send_resp(&1, 400, ~s({"error":"logprobs are not supported"})))
      assert {:error, {:http, 400, body}} = OpenAI.decide(type(), @input, cfg(:openai_400))
      assert body =~ "logprobs"

      Req.Test.stub(:openai_gone, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, _} = OpenAI.decide(type(), @input, cfg(:openai_gone, attempts: 1))
    end
  end

  describe "ask/4: the request other backends of this API share" do
    test "their name labels the model and its provider, and their headers are sent" do
      Req.Test.stub(:openai_wire, fn conn ->
        send(self(), {:title, Plug.Conn.get_req_header(conn, "x-title")})

        Req.Test.json(conn, %{
          "model" => "m",
          "provider" => "P",
          "choices" => [%{"message" => %{"content" => ~s({"value": "flaky"})}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2, "cost" => 0.25}
        })
      end)

      body = OpenAI.body(type(), @input, model: "m")
      wire = [name: :elsewhere, headers: [{"x-title", "Xeito"}]]

      assert {:ok, %{model: "elsewhere:m@P", cost: %{usd: 0.25, tokens_in: 1, tokens_out: 2}}} =
               OpenAI.ask(type(), body, cfg(:openai_wire), wire)

      assert_received {:title, ["Xeito"]}
    end
  end

  describe "chat/4 and probe/2" do
    test "chat is OpenAI's streamed completion, with no fields of another service" do
      Req.Test.stub(:openai_chat, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self(), {:sent, JSON.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, ~s(data: {"choices":[{"delta":{"content":"hello"}}]}\n\ndata: [DONE]\n\n))
      end)

      assert {:ok, %{content: "hello", model: "served-model", served_by: "openai:served-model"}} =
               OpenAI.chat([%{role: "user", content: "hi"}], [], cfg(:openai_chat), fn _ -> :ok end)

      assert_received {:sent, sent}
      assert Map.keys(sent) == ["messages", "model", "stream", "stream_options"]
    end

    test "the probe lists the models the server offers, or says it is down" do
      Req.Test.stub(
        :openai_models,
        &Req.Test.json(&1, %{"data" => [%{"id" => "a", "context_length" => 8192}, %{"id" => "b"}]})
      )

      assert OpenAI.probe(cfg(:openai_models), timeout: 100) ==
               %{up: true, loaded: [%{name: "a", context: 8192}, %{name: "b", context: nil}]}

      Req.Test.stub(:openai_down, &Plug.Conn.send_resp(&1, 500, "down"))
      assert OpenAI.probe(cfg(:openai_down), timeout: 100) == %{up: false, loaded: []}
    end
  end
end
