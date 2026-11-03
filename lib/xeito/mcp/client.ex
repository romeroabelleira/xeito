defmodule Xeito.Mcp.Client do
  @moduledoc """
  Behaviour of an MCP client adapter: one process per server, speaking the protocol through a
  library (`Xeito.Mcp.Anubis`), so Xeito writes no protocol of its own.

    * `start/1` starts the client for a server (`Xeito.Mcp.Config.server/0`), initialised.
    * `tools/1` lists the server's tools as `tools/list` returns them (maps with string keys).
    * `call/3` calls a tool and returns the result as `tools/call` returns it: `content`, maybe
      `structuredContent` and `isError`. A protocol failure is `{:error, reason}`.
    * `stop/1` ends the client and the server it started.
  """

  alias Xeito.Mcp.Config

  @typedoc "What `start/1` returns and the other callbacks take: the adapter's own handle on a server."
  @type handle :: term()

  @callback start(Config.server()) :: {:ok, handle()} | {:error, term()}
  @callback tools(handle()) :: {:ok, [map()]} | {:error, term()}
  @callback call(handle(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback stop(handle()) :: :ok
end
