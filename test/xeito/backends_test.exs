defmodule Xeito.BackendsTest do
  # One test registers a backend in the application environment, so the file runs serially.
  use ExUnit.Case, async: false

  alias Xeito.Backends
  alias Xeito.Chat
  alias Xeito.Decision
  alias Xeito.Decisions.Triage
  alias Xeito.Monitor.Models
  alias Xeito.Tiers
  alias Xeito.Tiers.Settings

  defmodule Whole do
    @moduledoc false
    @behaviour Backends

    @impl true
    def decide(_type, _input, cfg),
      do: {:ok, %{value: :flaky, probabilities: %{}, confidence: 1.0, model: cfg[:model], latency_ms: 0}}

    @impl true
    def chat(messages, tools, cfg, on_delta) do
      on_delta.("pong")

      {:ok,
       %{content: "pong", tool_calls: [], model: cfg[:model], tokens_in: length(messages), tokens_out: length(tools)}}
    end

    @impl true
    def probe(cfg, opts), do: %{up: true, loaded: [%{name: cfg[:model]}], asked: Keyword.keys(opts)}
    @impl true
    def loaded?(cfg), do: {:ok, cfg[:model] == "resident"}
    @impl true
    def load(_cfg), do: {:ok, 7}
    @impl true
    def default_url, do: "http://127.0.0.1:9"
    @impl true
    def spend, do: :priced
    @impl true
    def list_price(cfg), do: %{prompt: 1.0, model: cfg[:model]}
    @impl true
    def destination(cfg), do: "the test service at #{cfg[:url]}"
  end

  defmodule Bare do
    @moduledoc false
    @behaviour Backends

    @impl true
    def decide(_type, _input, _cfg), do: {:error, :undecided}
  end

  setup do
    Application.put_env(:xeito, :backends, %{whole: Whole, bare: Bare})
    on_exit(fn -> Application.delete_env(:xeito, :backends) end)
  end

  @cfg [url: "http://127.0.0.1:9", model: "m"]

  test "the built-in backends, and the ones the configuration adds" do
    assert Backends.names() == [:anthropic, :bare, :colibri, :ollama, :openai, :openrouter, :system_one, :whole]
    assert Backends.module(:colibri) == {:ok, Xeito.Backends.Colibri}
    assert Backends.module(:openai) == {:ok, Xeito.Backends.OpenAI}
    assert Backends.module(:whole) == {:ok, Whole}
    assert Backends.module(:cohere) == :error
  end

  describe "a backend that implements a callback is asked" do
    test "chat, probe, residency, URL, spend, price and destination" do
      assert {:ok, %{content: "pong", tokens_in: 1, tokens_out: 0}} =
               Backends.chat(:whole, [%{role: "user", content: "ping"}], [], @cfg, &send(self(), {:delta, &1}))

      assert_received {:delta, "pong"}

      assert Backends.probe(:whole, @cfg, timeout: 5, now: nil) == %{
               up: true,
               loaded: [%{name: "m"}],
               asked: [:timeout, :now]
             }

      assert Backends.loaded?(:whole, @cfg) == {:ok, false}
      assert Backends.loaded?(:whole, model: "resident") == {:ok, true}
      assert Backends.load(:whole, @cfg) == {:ok, 7}
      assert Backends.default_url(:whole) == "http://127.0.0.1:9"
      assert Backends.spend(:whole) == :priced
      assert Backends.list_price(:whole, @cfg) == %{prompt: 1.0, model: "m"}
      assert Backends.destination(:whole, @cfg) == "the test service at http://127.0.0.1:9"
    end
  end

  describe "a backend without a callback, or an unknown one, gets the default" do
    test "it cannot chat, holds its one model, has no URL, no cost and no price" do
      for backend <- [:bare, :cohere] do
        assert Backends.chat(backend, [], [], @cfg, fn _ -> :ok end) == {:error, {:no_chat_backend, backend}}
        assert Backends.probe(backend, @cfg, timeout: 5) == %{}
        assert Backends.loaded?(backend, @cfg) == {:ok, true}
        assert Backends.load(backend, @cfg) == {:ok, 0}
        assert Backends.default_url(backend) == nil
        assert Backends.spend(backend) == :none
        assert Backends.list_price(backend, @cfg) == nil
        assert Backends.destination(backend, @cfg) == "#{backend} at http://127.0.0.1:9"
      end
    end
  end

  describe "what each built-in backend says of itself" do
    test "only the hosted services have a public URL" do
      assert Backends.default_url(:openrouter) == "https://openrouter.ai/api"
      assert Backends.default_url(:anthropic) == "https://api.anthropic.com"
      for backend <- [:colibri, :ollama, :openai, :system_one], do: assert(Backends.default_url(backend) == nil)
    end

    test "OpenRouter bills, the Claude API is priced from its list, the others report no cost" do
      assert Backends.spend(:openrouter) == :billed
      assert Backends.spend(:anthropic) == :priced
      for backend <- [:colibri, :ollama, :openai, :system_one], do: assert(Backends.spend(backend) == :none)

      assert %{prompt: _} = Backends.list_price(:anthropic, model: "claude-sonnet-5-5")
      assert Backends.list_price(:anthropic, model: "unlisted") == nil
      assert Backends.list_price(:openrouter, model: "claude-sonnet-5-5") == nil
    end

    test "where a conversation goes" do
      assert Backends.destination(:openrouter, []) == "OpenRouter, zero data retention"
      assert Backends.destination(:anthropic, []) == "the Claude API"
    end

    test "every backend but the System One server chats; only Ollama has residency" do
      for backend <- [:anthropic, :colibri, :ollama, :openai, :openrouter] do
        {:ok, module} = Backends.module(backend)
        assert Code.ensure_loaded?(module) and function_exported?(module, :chat, 4), "#{backend} cannot chat"
      end

      assert Backends.chat(:system_one, [], [], @cfg, fn _ -> :ok end) == {:error, {:no_chat_backend, :system_one}}
      # A server that holds one model has nothing to swap, so the escalation never waits for one.
      for backend <- [:colibri, :openai, :system_one], do: assert(Backends.loaded?(backend, @cfg) == {:ok, true})
    end
  end

  describe "get/3: one bounded GET of a status path" do
    test "the body of a 200, the status of anything else, and a service that does not answer" do
      Req.Test.stub(:backends_get, fn conn ->
        case conn.request_path do
          "/ok" -> Req.Test.json(conn, %{"status" => "ok"})
          "/busy" -> Plug.Conn.send_resp(conn, 503, "restarting")
          "/gone" -> Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      cfg = [url: "http://status.test", plug: {Req.Test, :backends_get}]
      assert Backends.get(cfg, "/ok", 100) == {:ok, %{"status" => "ok"}}
      assert Backends.get(cfg, "/busy", 100) == {:error, {:http, 503}}
      assert Backends.get(cfg, "/gone", 100) == {:error, :unreachable}
    end
  end

  describe "a backend registered here alone is reached by every caller" do
    test "the settings accept its name and take its URL" do
      assert Settings.from_env(%{"XEITO_LOCAL_BACKEND" => "whole", "XEITO_LOCAL_MODEL" => "m"}, & &1) ==
               [local: [backend: :whole, url: "http://127.0.0.1:9", model: "m"]]
    end

    test "decisions, chat and the monitor go through it" do
      tier = [backend: :whole, url: "http://127.0.0.1:9", model: "m"]

      assert {:ok, %{value: :flaky, model: "m"}} = Tiers.run(:local, Decision.type!(Triage), %{}, tier)

      assert {:ok, %{content: "pong", tier: :local}} =
               Chat.complete([%{role: "user", content: "ping"}], [], [tier: :local] ++ tier)

      assert %{configured: true, model: "m", up: true, loaded: [%{name: "m"}]} = Models.read(tiers: [local: tier]).local
    end
  end
end
