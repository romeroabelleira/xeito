defmodule Xeito.Mcp.ConfigTest do
  use ExUnit.Case, async: true

  alias Xeito.Mcp.Config

  @moduletag :tmp_dir

  defp write!(dir, path, json) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, json)
    full
  end

  test "servers come from the workspace's .xeito/mcp.json and the user's mcp.json, the workspace's winning",
       %{tmp_dir: dir} do
    ws = Path.join(dir, "ws")
    home = Path.join(dir, "home")

    write!(ws, ".xeito/mcp.json", ~s({"servers": {"fixture": {"command": ["elixir", "server.exs"], "exposure": "direct"},
      "docs": {"url": "http://localhost:4000/mcp", "tools": {"search": "hidden"}}}}))

    write!(
      home,
      "xeito/mcp.json",
      ~s({"servers": {"docs": {"url": "http://other/mcp"}, "notes": {"command": ["notes-mcp"]}}})
    )

    assert {:ok,
            [
              %{
                name: "docs",
                transport: {:http, "http://localhost:4000/mcp"},
                exposure: :script,
                tools: %{"search" => :hidden}
              },
              %{name: "fixture", transport: {:stdio, "elixir", ["server.exs"]}, exposure: :direct, tools: %{}},
              %{name: "notes", transport: {:stdio, "notes-mcp", []}, exposure: :script, tools: %{}}
            ]} = Config.load(ws, config_home: home)

    assert {:ok, []} = Config.load(Path.join(dir, "empty"), config_home: Path.join(dir, "nohome"))
  end

  test "without :config_home, the user's file is under $XDG_CONFIG_HOME", %{tmp_dir: dir} do
    home = Path.join(dir, "xdg")
    write!(home, "xeito/mcp.json", ~s({"servers": {"notes": {"command": ["notes-mcp"]}}}))
    before = System.get_env("XDG_CONFIG_HOME")

    on_exit(fn ->
      if before, do: System.put_env("XDG_CONFIG_HOME", before), else: System.delete_env("XDG_CONFIG_HOME")
    end)

    System.put_env("XDG_CONFIG_HOME", home)
    assert {:ok, [%{name: "notes"}]} = Config.load(Path.join(dir, "empty"))
  end

  test "a bad file, server or level is an error naming it", %{tmp_dir: dir} do
    ws = Path.join(dir, "ws")
    home = Path.join(dir, "home")
    write!(ws, ".xeito/mcp.json", "{oops")
    assert {:error, ".xeito/mcp.json: " <> _} = Config.load(ws, config_home: home)

    write!(ws, ".xeito/mcp.json", ~s({"servers": {"x": {"exposure": "script"}}}))

    assert {:error, ".xeito/mcp.json: server x needs a command (stdio) or a url (streamable HTTP)"} =
             Config.load(ws, config_home: home)

    write!(ws, ".xeito/mcp.json", ~s({"servers": {"x": {"command": ["a"], "exposure": "loud"}}}))

    assert {:error, ".xeito/mcp.json: server x: unknown exposure \"loud\"; script, deferred, direct or hidden"} =
             Config.load(ws, config_home: home)

    write!(ws, ".xeito/mcp.json", ~s({"servers": {"x": {"command": ["a"], "tools": {"t": "loud"}}}}))
    assert {:error, ".xeito/mcp.json: server x, tool t: unknown exposure" <> _} = Config.load(ws, config_home: home)

    write!(ws, ".xeito/mcp.json", ~s({"servers": {"x": "mcp-x"}}))
    assert {:error, ".xeito/mcp.json: server x: expected an object"} = Config.load(ws, config_home: home)

    write!(ws, ".xeito/mcp.json", ~s({"servers": {"x": {"command": ["a"], "tools": ["t"]}}}))

    assert {:error, ".xeito/mcp.json: server x: tools is an object of tool names to levels"} =
             Config.load(ws, config_home: home)

    write!(ws, ".xeito/mcp.json", ~s({"servers": {"x": {"url": ""}}}))

    assert {:error, ".xeito/mcp.json: server x needs a command (stdio) or a url (streamable HTTP)"} =
             Config.load(ws, config_home: home)

    write!(ws, ".xeito/mcp.json", ~s({"servers": []}))
    assert {:error, ".xeito/mcp.json: expected {\"servers\": {...}}"} = Config.load(ws, config_home: home)

    File.rm!(Path.join(ws, ".xeito/mcp.json"))
    File.mkdir_p!(Path.join(ws, ".xeito/mcp.json"))
    assert {:error, ".xeito/mcp.json: :eisdir"} = Config.load(ws, config_home: home)
    File.rmdir!(Path.join(ws, ".xeito/mcp.json"))

    write!(ws, ".xeito/mcp.json", ~s({"servers": {"bad name": {"command": ["a"]}}}))

    assert {:error, ".xeito/mcp.json: server \"bad name\": a server's name is a short lowercase word" <> _} =
             Config.load(ws, config_home: home)
  end

  test "exposure/3: a tool's level is its own, else its server's, with script the default" do
    server = %{
      name: "docs",
      transport: {:http, "u"},
      exposure: :deferred,
      tools: %{"wipe" => :hidden, "search" => :direct}
    }

    assert Config.exposure(server, "wipe") == :hidden
    assert Config.exposure(server, "search") == :direct
    assert Config.exposure(server, "other") == :deferred
  end
end
