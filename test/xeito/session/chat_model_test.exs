defmodule Xeito.Session.ChatModelTest do
  use ExUnit.Case, async: true

  alias Xeito.Session.ChatModel

  @configs %{
    local: [backend: :ollama, model: "qwen", context: 81_920],
    remote: nil,
    remote_frontier: [backend: :openrouter, model: "anthropic/claude-sonnet-5.5"]
  }

  describe "choose/2" do
    test "a configured chat tier, by name" do
      assert ChatModel.choose("remote_frontier", @configs) == {:ok, :remote_frontier}
      assert ChatModel.choose(" local ", @configs) == {:ok, :local}
    end

    test "a tier that is not configured, or not a chat tier, is refused with the choices" do
      assert {:error, text} = ChatModel.choose("remote", @configs)
      assert text =~ "remote is not configured"
      assert text =~ "XEITO_REMOTE_MODEL"

      assert {:error, text} = ChatModel.choose("local_decision", @configs)
      assert text =~ "not a chat tier"
      assert text =~ "local, remote, remote_frontier"
    end
  end

  test "context/2: the local tier's window; a remote one's, or 128k" do
    assert ChatModel.context(:local, @configs.local) == 81_920
    assert ChatModel.context(:local, []) == nil
    assert ChatModel.context(:remote_frontier, @configs.remote_frontier) == 131_072
    assert ChatModel.context(:remote_frontier, context: 50_000) == 50_000
  end

  test "current/1: the session's choice, else the default" do
    assert ChatModel.current(tier: :remote) == :remote
    assert ChatModel.current([]) == :local
  end

  test "off_box?/1" do
    assert ChatModel.off_box?(:remote_frontier)
    refute ChatModel.off_box?(:local)
  end

  describe "describe/3" do
    test "the current tier, then every chat tier and how to switch" do
      text = ChatModel.describe(:local, @configs, nil)

      assert text =~ "chat: local · qwen"
      assert text =~ "  remote            not configured"
      assert text =~ "  remote_frontier   anthropic/claude-sonnet-5.5 · off-box"
      assert text =~ "/model <tier>"
      refute text =~ "left"
    end

    test "a remote tier shows what the key has left" do
      assert ChatModel.describe(:remote_frontier, @configs, 29.984) =~
               "chat: remote_frontier · anthropic/claude-sonnet-5.5 · off-box · OpenRouter key: $29.98 left"
    end
  end

  test "switched/3: what a switch to a remote tier means" do
    assert ChatModel.switched(:local, @configs.local, 0.5) == "chat: local · qwen"

    text = ChatModel.switched(:remote_frontier, @configs.remote_frontier, 0.5)
    assert text =~ "anthropic/claude-sonnet-5.5"
    assert text =~ "leave this machine"
    assert text =~ "$0.50 per turn"
  end
end
