defmodule Xeito.Backends.ColibriTest do
  use ExUnit.Case, async: true

  alias Xeito.Backends.Colibri
  alias Xeito.Decision
  alias Xeito.Decisions.Triage

  @input %{test: "CheckoutTest", output: "left: 107.0 right: 108.0", diff_stat: "lib/pricing.ex"}

  defp cfg(stub, extra \\ []), do: [url: "http://colibri.test", plug: {Req.Test, stub}] ++ extra

  defp sent(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(self(), {:sent, conn.request_path, JSON.decode!(raw)})
    conn
  end

  describe "decide/3: one choice question on /v1/systemone" do
    test "the served model scores the options; the reply's probabilities are the result's" do
      Req.Test.stub(:colibri_decide, fn conn ->
        conn = sent(conn)

        Req.Test.json(conn, %{
          "model" => "qwen36",
          "provider" => "colibri",
          "answers" => %{
            "triage" => %{
              "type" => "choice",
              "choice" => "code_bug",
              "probabilities" => %{"code_bug" => 0.9, "test_bug" => 0.06, "flaky" => 0.03, "env_problem" => 0.01},
              "confidence" => 0.87
            }
          },
          "usage" => %{"input_tokens" => 86, "output_tokens" => 15, "cost" => 0}
        })
      end)

      assert {:ok, %{value: :code_bug, confidence: 0.9, probabilities: probs, model: "colibri:qwen36", cost: cost}} =
               Colibri.decide(Decision.type!(Triage), @input, cfg(:colibri_decide, model: "qwen36"))

      assert probs[:test_bug] == 0.06
      assert %{tokens_in: 86, tokens_out: 0} = cost

      assert_received {:sent, "/v1/systemone", body}
      assert body["model"] == "qwen36"
      assert %{"triage" => %{"type" => "choice", "criteria" => criteria}} = body["questions"]
      assert Map.keys(criteria) == ["code_bug", "env_problem", "flaky", "test_bug"]
      assert body["state"]["test"] == "CheckoutTest"
    end

    test "a tier without a model sends none and is named by the reply, else as served" do
      answers = %{"answers" => %{"triage" => %{"choice" => "flaky"}}}
      Req.Test.stub(:colibri_unnamed, &(&1 |> sent() |> Req.Test.json(answers)))
      Req.Test.stub(:colibri_named, &Req.Test.json(&1, Map.put(answers, "model", "laya")))
      type = Decision.type!(Triage)

      assert {:ok, %{value: :flaky, confidence: 1.0, model: "colibri:served"}} =
               Colibri.decide(type, @input, cfg(:colibri_unnamed))

      assert_received {:sent, "/v1/systemone", body}
      refute Map.has_key?(body, "model")

      assert {:ok, %{model: "colibri:laya"}} = Colibri.decide(type, @input, cfg(:colibri_named))
      assert {:ok, %{model: "colibri:qwen36"}} = Colibri.decide(type, @input, cfg(:colibri_unnamed, model: "qwen36"))
    end

    test "a server that refuses, or does not answer, is an error" do
      Req.Test.stub(
        :colibri_404,
        &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => %{"code" => "model_not_found"}}))
      )

      assert {:error, {:http, 404, %{"error" => %{"code" => "model_not_found"}}}} =
               Colibri.decide(Decision.type!(Triage), @input, cfg(:colibri_404, model: "other"))

      Req.Test.stub(:colibri_gone, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Colibri.decide(Decision.type!(Triage), @input, cfg(:colibri_gone))
    end
  end

  describe "body/3: the chat request" do
    test "OpenAI's, with the server's own summarising off; thinking only when the tier sets it" do
      body = Colibri.body([%{role: "user", content: "hi"}], [%{type: "function"}], model: "qwen36")

      assert body == %{
               model: "qwen36",
               messages: [%{role: "user", content: "hi"}],
               stream: true,
               stream_options: %{include_usage: true},
               tools: [%{type: "function"}],
               context_compaction: "off"
             }

      assert Colibri.body([], [], model: "qwen36", think: true).enable_thinking == true
      refute Map.has_key?(Colibri.body([], [], model: "qwen36", think: false), :enable_thinking)
      assert Colibri.body([], [], model: "qwen36", max_tokens: 512).max_tokens == 512
    end
  end

  describe "chat/4" do
    test "a streamed answer with a tool call, served by the model the server names" do
      Req.Test.stub(:colibri_chat, fn conn ->
        conn = sent(conn)

        events = [
          %{choices: [%{delta: %{content: "Reading."}}]},
          %{choices: [%{delta: %{tool_calls: [%{index: 0, function: %{name: "read", arguments: ~s({"path":)}}]}}]},
          %{
            choices: [
              %{delta: %{tool_calls: [%{index: 0, function: %{arguments: ~s("a.ex"})}}]}, finish_reason: "tool_calls"}
            ]
          },
          %{model: "qwen36", choices: [], usage: %{prompt_tokens: 40, completion_tokens: 9}}
        ]

        body = Enum.map_join(events, &("data: " <> JSON.encode!(&1) <> "\n\n")) <> "data: [DONE]\n\n"
        conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_resp(200, body)
      end)

      parent = self()

      assert {:ok, reply} =
               Colibri.chat(
                 [%{role: "user", content: "read a.ex"}],
                 [%{type: "function"}],
                 cfg(:colibri_chat, model: "qwen36"),
                 &send(parent, {:delta, &1})
               )

      assert %{content: "Reading.", tool_calls: [%{name: "read", arguments: %{"path" => "a.ex"}}]} = reply
      assert %{model: "qwen36", served_by: "colibri:qwen36", tokens_in: 40, tokens_out: 9, usd: +0.0} = reply
      assert_received {:delta, "Reading."}

      assert_received {:sent, "/v1/chat/completions",
                       %{"model" => "qwen36", "context_compaction" => "off", "stream" => true}}
    end

    test "a full queue is retried; a model the server does not serve is an error" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(:colibri_busy, fn conn ->
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
          Plug.Conn.send_resp(conn, 429, ~s({"error":{"code":"queue_timeout"}}))
        else
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream")
          |> Plug.Conn.send_resp(200, ~s(data: {"choices":[{"delta":{"content":"ok"}}]}\n\n))
        end
      end)

      parent = self()
      cfg = cfg(:colibri_busy, model: "qwen36", sleep: &send(parent, {:slept, &1}))
      assert {:ok, %{content: "ok"}} = Colibri.chat([], [], cfg, fn _ -> :ok end)
      assert_received {:slept, _ms}

      Req.Test.stub(:colibri_other, &Plug.Conn.send_resp(&1, 404, ~s({"error":{"code":"model_not_found"}})))
      assert {:error, {:http, 404, _}} = Colibri.chat([], [], cfg(:colibri_other, model: "other"), fn _ -> :ok end)
    end
  end

  describe "probe/2" do
    defp server(stub, health, models) do
      Req.Test.stub(stub, fn conn ->
        case {conn.request_path, health} do
          {"/health", {status, body}} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
          {"/health", :gone} -> Req.Test.transport_error(conn, :econnrefused)
          {"/v1/models", _} -> Req.Test.json(conn, models)
        end
      end)

      cfg(stub)
    end

    @served %{"data" => [%{"id" => "qwen36", "context_length" => 65_536}]}

    test "a running server holds the one model it serves, with its context" do
      cfg = server(:colibri_up, {200, %{"status" => "ok", "kv_slots" => 1}}, @served)

      assert Colibri.probe(cfg ++ [model: "qwen36"], timeout: 100) ==
               %{up: true, loaded: [%{name: "qwen36", context: 65_536}], mismatch: false}

      assert %{mismatch: false} = Colibri.probe(cfg, timeout: 100)
    end

    test "a tier configured for another model than the served one says so" do
      cfg = server(:colibri_mismatch, {200, %{"status" => "ok"}}, @served)

      assert %{up: true, mismatch: true, loaded: [%{name: "qwen36"}]} =
               Colibri.probe(cfg ++ [model: "qwen38"], timeout: 100)
    end

    test "a server whose engine restarts is not up, and says why" do
      cfg = server(:colibri_restarting, {503, %{"status" => "restarting"}}, @served)
      assert Colibri.probe(cfg, timeout: 100) == %{up: false, loaded: [], status: "restarting"}
    end

    test "a server that does not answer is down; one that lists no models is up with none" do
      assert Colibri.probe(server(:colibri_down, :gone, @served), timeout: 100) == %{up: false, loaded: []}
      assert Colibri.probe(server(:colibri_500, {500, %{}}, @served), timeout: 100) == %{up: false, loaded: []}

      assert Colibri.probe(server(:colibri_odd, {200, %{"status" => "ok"}}, %{"error" => "x"}), timeout: 100) == %{
               up: true,
               loaded: [],
               mismatch: false
             }
    end
  end
end
