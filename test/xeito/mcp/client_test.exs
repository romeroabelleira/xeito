defmodule Xeito.Mcp.ClientTest do
  # Each adapter starts the fixture server (`test/support/mcp/server.exs`) as a real process: not async.
  use ExUnit.Case, async: false

  @moduletag :mcp

  @fixture %{name: "fx", transport: {:stdio, "elixir", ["test/support/mcp/server.exs"]}, exposure: :script, tools: %{}}

  # arbor_mcp was tried here side by side and passed the same tests; it left with its advisory-carrying jsv.
  for adapter <- [Xeito.Mcp.Anubis] do
    @adapter adapter

    describe "#{inspect(adapter)}" do
      test "starts the server, lists its tools with their annotations, calls one, and reports a tool's own error" do
        Process.flag(:trap_exit, true)
        assert {:ok, pid} = @adapter.start(@fixture)

        assert {:ok, tools} = @adapter.tools(pid)

        assert [
                 %{"name" => "echo", "annotations" => %{"readOnlyHint" => true}},
                 %{"name" => "lookup"},
                 %{"name" => "wipe"}
               ] =
                 Enum.sort_by(tools, & &1["name"])

        assert {:ok, %{"content" => [%{"type" => "text", "text" => "hi"}]}} =
                 @adapter.call(pid, "echo", %{"text" => "hi"})

        assert {:ok, %{"isError" => true, "content" => [%{"text" => "unknown tool nope"}]}} =
                 @adapter.call(pid, "nope", %{})

        assert :ok = @adapter.stop(pid)
      end

      test "a server that cannot start is an error, not a crash" do
        Process.flag(:trap_exit, true)
        assert {:error, _reason} = @adapter.start(%{@fixture | transport: {:stdio, "no-such-mcp-server-xyz", []}})
      end
    end
  end
end
