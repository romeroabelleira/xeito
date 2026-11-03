defmodule Xeito.Mcp.ServersTest do
  # Starts the fixture MCP server as a real process: not async.
  use ExUnit.Case, async: false

  alias Xeito.Effect
  alias Xeito.Effects.Local
  alias Xeito.Mcp.Servers

  @moduletag :mcp
  @moduletag :tmp_dir

  defp workspace!(dir, servers) do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(Path.join(ws, ".xeito"))
    File.write!(Path.join(ws, ".xeito/mcp.json"), JSON.encode!(%{"servers" => servers}))
    on_exit(fn -> Servers.stop(ws) end)
    ws
  end

  defp fixture(extra \\ %{}), do: Map.merge(%{"command" => ["elixir", Path.expand("test/support/mcp/server.exs")]}, extra)

  test "the workspace's servers start on first use; their tools carry their exposure; calls reach them", %{tmp_dir: dir} do
    ws = workspace!(dir, %{"fx" => fixture(%{"exposure" => "deferred", "tools" => %{"wipe" => "hidden"}})})
    home = Path.join(dir, "nohome")

    assert {:ok, tools} = Servers.tools(ws, config_home: home)

    assert [
             %{server: "fx", name: "echo", exposure: :deferred, annotations: %{"readOnlyHint" => true}},
             %{name: "lookup", exposure: :deferred},
             %{name: "wipe", exposure: :hidden}
           ] = Enum.sort_by(tools, & &1.name)

    assert {:ok, %{"content" => [%{"text" => "hi"}]}} = Servers.call(ws, "fx", "echo", %{"text" => "hi"})
    assert {:error, "no MCP server named \"other\""} = Servers.call(ws, "other", "echo", %{})

    # Through the runner: an mcp effect, with the result's text as its content.
    effect = Effect.mcp("fx", "echo", %{"text" => "from the runner"}, cwd: ws)
    assert %{ok: true, content: "from the runner"} = Local.run(effect, [])
    assert %{ok: false, error: "unknown tool nope"} = Local.run(Effect.mcp("fx", "nope", %{}, cwd: ws), [])
    assert %{ok: false, error: "no MCP server named \"other\""} = Local.run(Effect.mcp("other", "echo", %{}, cwd: ws), [])
  end

  test "a server that cannot start has no tools and fails its calls; a bad configuration is reported", %{tmp_dir: dir} do
    ws = workspace!(dir, %{"gone" => %{"command" => ["no-such-mcp-server-xyz"]}, "fx" => fixture()})
    home = Path.join(dir, "nohome")

    assert {:ok, tools} = Servers.tools(ws, config_home: home)
    assert tools |> Enum.map(& &1.server) |> Enum.uniq() == ["fx"]
    assert {:error, "server gone could not start: " <> _} = Servers.call(ws, "gone", "x", %{})

    bad = Path.join(dir, "bad")
    File.mkdir_p!(Path.join(bad, ".xeito"))
    File.write!(Path.join(bad, ".xeito/mcp.json"), "{nope")
    on_exit(fn -> Servers.stop(bad) end)
    assert {:error, ".xeito/mcp.json: not JSON" <> _} = Servers.tools(bad, config_home: home)
    assert {:error, ".xeito/mcp.json: not JSON" <> _} = Servers.call(bad, "fx", "echo", %{})
  end

  test "a workspace without a configuration has no servers, and stop/1 is fine with that", %{tmp_dir: dir} do
    ws = Path.join(dir, "plain")
    File.mkdir_p!(ws)
    assert {:ok, []} = Servers.tools(ws, config_home: Path.join(dir, "nohome"))
    assert :ok = Servers.stop(ws)
    assert :ok = Servers.stop(ws)
  end
end
