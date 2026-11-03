defmodule Xeito.McpTest do
  # Starts the fixture MCP server as a real process: not async.
  use ExUnit.Case, async: false

  alias Xeito.Mcp
  alias Xeito.Mcp.Servers

  defp tool(name, exposure, annotations \\ %{"openWorldHint" => false}),
    do: %{
      server: "fx",
      name: name,
      description: "does #{name}",
      schema: %{},
      annotations: annotations,
      exposure: exposure
    }

  defp tools,
    do: [
      tool("echo", :direct),
      tool("lookup", :deferred, %{"openWorldHint" => true}),
      tool("grep", :script),
      tool("wipe", :hidden)
    ]

  test "direct/1 and deferred/1 pick by exposure" do
    assert [%{name: "echo"}] = Mcp.direct(tools())
    assert [%{name: "lookup"}] = Mcp.deferred(tools())
  end

  test "allowed?/2: an open-world tool is off-box, so it needs the network setting; a closed-world one does not" do
    assert Mcp.allowed?(tool("echo", :direct), :forbidden)
    refute Mcp.allowed?(tool("lookup", :deferred, %{"openWorldHint" => true}), :forbidden)
    assert Mcp.allowed?(tool("lookup", :deferred, %{"openWorldHint" => true}), :allowed)
    assert Mcp.allowed?(tool("lookup", :deferred, %{"openWorldHint" => true}), ["a.test"])
    refute Mcp.allowed?(tool("unsaid", :script, %{}), :forbidden)

    assert Mcp.refusal(tool("lookup", :deferred, %{"openWorldHint" => true}), :forbidden) =~
             "refused: fx__lookup reaches outside"

    assert Mcp.refusal(tool("echo", :direct), :forbidden) == nil
  end

  test "prompt_section/2 names the deferred tools for scripts, and a configuration error" do
    assert Mcp.prompt_section(tools(), nil) ==
             "\n\nMCP tools reachable from scripts (Script.mcp(server, tool, args)):\n- fx.lookup: does lookup\n"

    assert Mcp.prompt_section([], nil) == ""
    assert Mcp.prompt_section([], "bad json") == "\n\n(MCP servers not available: bad json)\n"
  end

  @tag :tmp_dir
  test "tools/2: a workspace without servers has none; hidden tools are left out of a configured one", %{tmp_dir: dir} do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    on_exit(fn -> Servers.stop(ws) end)
    assert {[], nil} = Mcp.tools(ws, config_home: Path.join(dir, "nohome"))

    bad = Path.join(dir, "bad")
    File.mkdir_p!(Path.join(bad, ".xeito"))
    File.write!(Path.join(bad, ".xeito/mcp.json"), "{")
    on_exit(fn -> Servers.stop(bad) end)
    assert {[], ".xeito/mcp.json: not JSON" <> _} = Mcp.tools(bad, config_home: Path.join(dir, "nohome"))

    live = Path.join(dir, "live")
    File.mkdir_p!(Path.join(live, ".xeito"))

    File.write!(
      Path.join(live, ".xeito/mcp.json"),
      JSON.encode!(%{
        "servers" => %{
          "fx" => %{
            "command" => ["elixir", Path.expand("test/support/mcp/server.exs")],
            "exposure" => "direct",
            "tools" => %{"wipe" => "hidden"}
          }
        }
      })
    )

    on_exit(fn -> Servers.stop(live) end)
    assert {tools, nil} = Mcp.tools(live, config_home: Path.join(dir, "nohome"))
    assert Enum.map(tools, &{&1.name, &1.exposure}) == [{"echo", :direct}, {"lookup", :direct}]
  end
end
