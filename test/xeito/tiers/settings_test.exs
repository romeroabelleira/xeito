defmodule Xeito.Tiers.SettingsTest do
  use ExUnit.Case, async: true

  alias Xeito.Tiers.Settings

  # Key files are read through the injected reader: the test's "file" is its own path.
  defp read(path), do: "key-of-" <> path

  defp tiers(env), do: Settings.from_env(env, &read/1)

  test "nothing set: no tier is configured" do
    assert tiers(%{}) == []
  end

  test "a local tier is configured by its URL and speaks its default backend" do
    env = %{
      "XEITO_LOCAL_URL" => "http://127.0.0.1:11434",
      "XEITO_LOCAL_MODEL" => "qwen3.8:27b",
      "XEITO_LOCAL_CONTEXT" => "65536",
      "XEITO_LOCAL_KEEP_ALIVE" => "5m",
      "XEITO_LOCAL_DECISION_URL" => "http://127.0.0.1:8082",
      "XEITO_LOCAL_DECISION_KEY_FILE" => "laya.key"
    }

    assert tiers(env) == [
             local_decision: [backend: :system_one, url: "http://127.0.0.1:8082", api_key: "key-of-laya.key"],
             local: [
               backend: :ollama,
               url: "http://127.0.0.1:11434",
               model: "qwen3.8:27b",
               context: 65_536,
               keep_alive: "5m"
             ]
           ]
  end

  test "a remote tier needs both its model and its key file, and defaults to OpenRouter" do
    assert tiers(%{"XEITO_REMOTE_MODEL" => "qwen/qwen3.8-27b"}) == []
    assert tiers(%{"XEITO_REMOTE_KEY_FILE" => "or.key"}) == []

    env = %{"XEITO_REMOTE_MODEL" => "qwen/qwen3.8-27b", "XEITO_REMOTE_KEY_FILE" => "or.key"}

    assert tiers(env) == [
             remote: [
               backend: :openrouter,
               url: "https://openrouter.ai/api",
               model: "qwen/qwen3.8-27b",
               api_key: "key-of-or.key"
             ]
           ]
  end

  test "one OpenRouter key does not switch on both remote tiers" do
    env = %{
      "XEITO_REMOTE_MODEL" => "qwen/qwen3.8-27b",
      "XEITO_REMOTE_KEY_FILE" => "or.key",
      "XEITO_REMOTE_FRONTIER_KEY_FILE" => "or.key"
    }

    assert Keyword.keys(tiers(env)) == [:remote]

    env = Map.put(env, "XEITO_REMOTE_FRONTIER_MODEL", "anthropic/claude-sonnet-5.5")
    assert Keyword.keys(tiers(env)) == [:remote, :remote_frontier]
  end

  test "OpenRouter's provider pins and retention setting are read for an OpenRouter tier" do
    env = %{
      "XEITO_REMOTE_FRONTIER_MODEL" => "m",
      "XEITO_REMOTE_FRONTIER_KEY_FILE" => "or.key",
      "XEITO_REMOTE_FRONTIER_PROVIDERS" => "Parasail,DeepInfra",
      "XEITO_REMOTE_FRONTIER_ZDR" => "false"
    }

    assert [remote_frontier: cfg] = tiers(env)
    assert cfg[:providers] == ["Parasail", "DeepInfra"]
    assert cfg[:zdr] == false
  end

  test "the hosted System One tier has no default URL: it needs one, its model and its key" do
    env = %{"XEITO_REMOTE_DECISION_MODEL" => "jev", "XEITO_REMOTE_DECISION_KEY_FILE" => "jev.key"}
    assert tiers(env) == []

    env = Map.put(env, "XEITO_REMOTE_DECISION_URL", "https://decisions.example")

    assert tiers(env) == [
             remote_decision: [
               backend: :system_one,
               url: "https://decisions.example",
               model: "jev",
               api_key: "key-of-jev.key"
             ]
           ]
  end

  test "a backend can be named; an unknown one stops the configuration with the setting's name" do
    env = %{"XEITO_LOCAL_URL" => "http://x", "XEITO_LOCAL_BACKEND" => "openrouter"}
    assert [local: [backend: :openrouter, url: "http://x"]] = tiers(env)

    assert_raise ArgumentError, ~r/XEITO_LOCAL_BACKEND: unknown backend "cohere"/, fn ->
      tiers(%{"XEITO_LOCAL_URL" => "http://x", "XEITO_LOCAL_BACKEND" => "cohere"})
    end
  end

  test "a context that is not a whole number stops the configuration with the setting's name" do
    assert_raise ArgumentError, ~r/XEITO_LOCAL_CONTEXT: not a whole number: "80k"/, fn ->
      tiers(%{"XEITO_LOCAL_URL" => "http://x", "XEITO_LOCAL_CONTEXT" => "80k"})
    end
  end

  describe "app_env/1" do
    test "the chat tier and the spend limit per run, when set" do
      assert Settings.app_env(%{}) == []

      assert Settings.app_env(%{"XEITO_CHAT_TIER" => "remote_frontier", "XEITO_MAX_USD_PER_RUN" => "2"}) == [
               chat_tier: :remote_frontier,
               policy: [max_usd_per_run: 2.0]
             ]
    end

    test "an unknown tier or an amount that is not one is refused at start" do
      assert_raise ArgumentError, ~r/XEITO_CHAT_TIER: unknown tier "big"/, fn ->
        Settings.app_env(%{"XEITO_CHAT_TIER" => "big"})
      end

      for bad <- ["lots", "-1", "2 usd"] do
        assert_raise ArgumentError, ~r/XEITO_MAX_USD_PER_RUN/, fn ->
          Settings.app_env(%{"XEITO_MAX_USD_PER_RUN" => bad})
        end
      end
    end
  end

  test "a remote tier's reasoning effort" do
    env = %{
      "XEITO_REMOTE_FRONTIER_MODEL" => "a/b",
      "XEITO_REMOTE_FRONTIER_KEY_FILE" => "k",
      "XEITO_REMOTE_FRONTIER_REASONING" => "high"
    }

    assert [remote_frontier: cfg] = tiers(env)
    assert cfg[:reasoning] == "high"
  end

  test "a remote tier on the anthropic backend defaults to the Claude API's URL" do
    env = %{
      "XEITO_REMOTE_FRONTIER_BACKEND" => "anthropic",
      "XEITO_REMOTE_FRONTIER_MODEL" => "claude-opus-5-5",
      "XEITO_REMOTE_FRONTIER_KEY_FILE" => "op://Private/Xeito Claude API Key/credential"
    }

    assert tiers(env) == [
             remote_frontier: [
               backend: :anthropic,
               url: "https://api.anthropic.com",
               model: "claude-opus-5-5",
               api_key: "key-of-op://Private/Xeito Claude API Key/credential"
             ]
           ]
  end

  test "a remote tier whose key cannot be read is not configured" do
    env = %{"XEITO_REMOTE_MODEL" => "qwen/qwen3.8-27b", "XEITO_REMOTE_KEY_FILE" => "op://Private/x/credential"}
    assert Settings.from_env(env, fn _ref -> nil end) == []
  end

  describe "read_key/2" do
    import ExUnit.CaptureIO

    test "an op:// reference is read with the 1Password CLI, trimmed" do
      cmd = fn "op", ["read", "--no-newline", ref], [stderr_to_stdout: true] -> {"key-for-#{ref}\n", 0} end
      assert Settings.read_key("op://Private/x/credential", cmd) == "key-for-op://Private/x/credential"
    end

    test "a reference op cannot read gives no key, with a warning" do
      cmd = fn "op", _args, _opts -> {"[ERROR] connecting to desktop app", 1} end

      assert capture_io(:stderr, fn -> send(self(), {:key, Settings.read_key("op://Private/x/credential", cmd)}) end) =~
               "connecting to desktop app"

      assert_received {:key, nil}
    end

    test "op missing altogether gives no key, with a warning" do
      cmd = fn _, _, _ -> raise ErlangError, original: :enoent end

      assert capture_io(:stderr, fn -> send(self(), {:key, Settings.read_key("op://Private/x/c", cmd)}) end) =~
               "op read failed"

      assert_received {:key, nil}
    end

    @tag :tmp_dir
    test "a path is the file's content, trimmed", %{tmp_dir: dir} do
      path = Path.join(dir, "k.key")
      File.write!(path, "secret\n")
      assert Settings.read_key(path) == "secret"
    end
  end
end
