# A small MCP server over stdio (newline-delimited JSON-RPC 2.0), for the tests of Xeito.Mcp:
# `elixir test/support/mcp/server.exs`. Two tools: `echo` (read-only, closed world) echoes its
# `text`; `wipe` (destructive) answers "wiped <target>"; `lookup` (read-only, open world).
defmodule Fixture do
  @moduledoc false
  @tools [
    %{
      "name" => "echo",
      "description" => "Echoes the text it is given, for tests",
      "inputSchema" => %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}, "required" => ["text"]},
      "annotations" => %{"readOnlyHint" => true, "openWorldHint" => false}
    },
    %{
      "name" => "wipe",
      "description" => "Wipes a target, for tests of destructive tools",
      "inputSchema" => %{"type" => "object", "properties" => %{"target" => %{"type" => "string"}}},
      "annotations" => %{"readOnlyHint" => false, "destructiveHint" => true, "openWorldHint" => false}
    },
    %{
      "name" => "lookup",
      "description" => "Looks a word up on the web, for tests of open-world tools",
      "inputSchema" => %{"type" => "object", "properties" => %{"word" => %{"type" => "string"}}},
      "annotations" => %{"readOnlyHint" => true, "openWorldHint" => true}
    }
  ]

  # Ends with the input: a server whose client is gone must not outlive it.
  def loop do
    case IO.gets("") do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line ->
        line |> JSON.decode!() |> handle() |> reply()
        loop()
    end
  end

  defp handle(%{"method" => "initialize", "id" => id, "params" => params}) do
    %{
      "id" => id,
      "result" => %{
        "protocolVersion" => params["protocolVersion"] || "2025-06-18",
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "fixture", "version" => "0.1.0"}
      }
    }
  end

  defp handle(%{"method" => "ping", "id" => id}), do: %{"id" => id, "result" => %{}}
  defp handle(%{"method" => "tools/list", "id" => id}), do: %{"id" => id, "result" => %{"tools" => @tools}}

  defp handle(%{"method" => "tools/call", "id" => id, "params" => %{"name" => name, "arguments" => args}}),
    do: %{"id" => id, "result" => call(name, args || %{})}

  defp handle(%{"method" => "tools/call", "id" => id, "params" => %{"name" => name}}),
    do: %{"id" => id, "result" => call(name, %{})}

  defp handle(%{"id" => id, "method" => method}),
    do: %{"id" => id, "error" => %{"code" => -32_601, "message" => "unknown method #{method}"}}

  # A notification: nothing to answer.
  defp handle(_notification), do: nil

  defp call("echo", %{"text" => text}), do: %{"content" => [%{"type" => "text", "text" => text}]}
  defp call("wipe", args), do: %{"content" => [%{"type" => "text", "text" => "wiped #{args["target"]}"}]}
  defp call("lookup", args), do: %{"content" => [%{"type" => "text", "text" => "#{args["word"]}: a word"}]}
  defp call(name, _args), do: %{"content" => [%{"type" => "text", "text" => "unknown tool #{name}"}], "isError" => true}

  defp reply(nil), do: :ok
  defp reply(message), do: IO.write(JSON.encode!(Map.put(message, "jsonrpc", "2.0")) <> "\n")
end

Fixture.loop()
