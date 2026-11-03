defmodule Xeito.Mcp.Anubis do
  @moduledoc """
  `Xeito.Mcp.Client` through anubis_mcp: a supervisor holding the client and its transport,
  named in `Xeito.Mcp.Registry`, initialised before `start/1` returns.
  """

  @behaviour Xeito.Mcp.Client

  alias Anubis.Client
  alias Anubis.MCP.Response

  @client_info %{"name" => "xeito", "version" => "0.1.0"}
  @protocol_version "2025-06-18"
  @ready_ms 15_000

  @impl true
  def start(%{name: name, transport: transport}) do
    ref = make_ref()
    client = {:via, Registry, {Xeito.Mcp.Registry, {:anubis, name, ref}}}

    opts = [
      name: client,
      transport_name: {:via, Registry, {Xeito.Mcp.Registry, {:anubis_transport, name, ref}}},
      transport: transport(transport),
      client_info: @client_info,
      protocol_version: @protocol_version
    ]

    with {:ok, sup} <- Client.start_link(opts) do
      case ready(client) do
        :ok ->
          {:ok, %{sup: sup, client: client}}

        {:error, reason} ->
          Supervisor.stop(sup)
          {:error, reason}
      end
    end
  end

  defp transport({:stdio, command, args}), do: {:stdio, command: command, args: args}
  defp transport({:http, url}), do: {:streamable_http, base_url: url}

  defp ready(client) do
    Client.await_ready(client, timeout: @ready_ms)
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def tools(%{client: client}) do
    with {:ok, %Response{result: %{"tools" => tools}}} <- Client.list_tools(client), do: {:ok, tools}
  end

  @impl true
  def call(%{client: client}, name, args) do
    case Client.call_tool(client, name, args) do
      {:ok, %Response{result: result}} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def stop(%{sup: sup}) do
    Supervisor.stop(sup)
  catch
    :exit, _ -> :ok
  end
end
