defmodule Xeito.Mcp.Servers do
  @moduledoc """
  The MCP servers of one workspace: a process that starts each configured server
  (`Xeito.Mcp.Config`) through the client adapter on the workspace's first use, lists their
  tools once, and hands out the clients.

    * `tools/2`: every tool with its `exposure`, or the configuration's error.
    * `call/4`: calls a tool on its server; the call runs in the caller, not here, so a slow
      tool does not hold the others.
    * A server that fails to start is remembered as such: no tools, and its calls fail with the
      reason. `stop/1` ends the process and its servers; an idle one ends after `@idle_ms`.

  The adapter is `config :xeito, :mcp_client` (default `Xeito.Mcp.Anubis`).
  """

  use GenServer

  alias Xeito.Mcp.Config
  alias Xeito.Mcp.Tool

  @idle_ms 1_800_000
  @registry Xeito.Mcp.Registry
  @supervisor Xeito.Mcp.Supervisor

  @type tool :: %{
          server: String.t(),
          name: String.t(),
          description: String.t(),
          schema: map(),
          annotations: map(),
          exposure: Config.exposure()
        }

  @doc "The workspace's tools, each with its exposure. Options: `:config_home` (`Xeito.Mcp.Config.load/2`)."
  @spec tools(Path.t(), keyword()) :: {:ok, [tool()]} | {:error, String.t()}
  def tools(cwd, opts \\ []), do: GenServer.call(find_or_start(cwd, opts), :tools, :infinity)

  @doc "Calls `tool` on `server` with `args`: the result as the server gave it, or why not."
  @spec call(Path.t(), String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(cwd, server, tool, args, opts \\ []) do
    with {:ok, {adapter, client}} <- GenServer.call(find_or_start(cwd, opts), {:client, server}, :infinity),
         do: adapter.call(client, tool, args)
  end

  @doc "Stops the workspace's servers, if any are running."
  @spec stop(Path.t()) :: :ok
  def stop(cwd) do
    case Registry.lookup(@registry, {:servers, Path.expand(cwd)}) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp find_or_start(cwd, opts) do
    cwd = Path.expand(cwd)
    spec = %{id: __MODULE__, start: {__MODULE__, :start_link, [cwd, opts]}, restart: :temporary}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc false
  def start_link(cwd, opts),
    do: GenServer.start_link(__MODULE__, {cwd, opts}, name: {:via, Registry, {@registry, {:servers, cwd}}})

  @impl true
  def init({cwd, opts}) do
    Process.flag(:trap_exit, true)
    {:ok, %{cwd: cwd, opts: opts, loaded: false, config: nil, clients: %{}, tools: []}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    case Config.load(state.cwd, state.opts) do
      {:ok, servers} ->
        {clients, tools} = Enum.reduce(servers, {%{}, []}, &start_server/2)
        {:noreply, %{state | loaded: true, config: :ok, clients: clients, tools: tools}, @idle_ms}

      {:error, reason} ->
        {:noreply, %{state | loaded: true, config: {:error, reason}}, @idle_ms}
    end
  end

  defp start_server(server, {clients, tools}) do
    adapter = Application.get_env(:xeito, :mcp_client, Xeito.Mcp.Anubis)

    with {:ok, client} <- adapter.start(server),
         {:ok, listed} <- adapter.tools(client) do
      found =
        for entry <- listed,
            tool = Tool.from_listing(server.name, entry),
            do: Map.put(tool, :exposure, Config.exposure(server, tool.name))

      {Map.put(clients, server.name, {adapter, client}), tools ++ found}
    else
      {:error, reason} -> {Map.put(clients, server.name, {:error, reason}), tools}
    end
  end

  @impl true
  def handle_call(:tools, _from, %{config: {:error, reason}} = state), do: {:reply, {:error, reason}, state, @idle_ms}
  def handle_call(:tools, _from, state), do: {:reply, {:ok, state.tools}, state, @idle_ms}

  def handle_call({:client, _server}, _from, %{config: {:error, reason}} = state),
    do: {:reply, {:error, reason}, state, @idle_ms}

  def handle_call({:client, server}, _from, state) do
    reply =
      case Map.fetch(state.clients, server) do
        {:ok, {:error, reason}} -> {:error, "server #{server} could not start: #{inspect(reason)}"}
        {:ok, client} -> {:ok, client}
        :error -> {:error, "no MCP server named #{inspect(server)}"}
      end

    {:reply, reply, state, @idle_ms}
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}
  def handle_info(_other, state), do: {:noreply, state, @idle_ms}

  @impl true
  def terminate(_reason, state) do
    for {_name, {adapter, client}} <- state.clients, adapter != :error, do: adapter.stop(client)
    :ok
  end
end
