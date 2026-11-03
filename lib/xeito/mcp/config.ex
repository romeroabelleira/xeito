defmodule Xeito.Mcp.Config do
  @moduledoc """
  The MCP servers a workspace may reach, from `.xeito/mcp.json` in the workspace and `mcp.json`
  in the user's Xeito configuration directory (`$XDG_CONFIG_HOME/xeito`), the workspace's
  winning for a server of the same name.

      {"servers": {"docs": {"url": "http://localhost:4000/mcp", "exposure": "deferred",
                            "tools": {"search": "direct", "purge": "hidden"}},
                   "notes": {"command": ["notes-mcp", "--root", "."]}}}

  A server has a `command` (stdio: the program and its arguments) or a `url` (streamable HTTP),
  an `exposure` for its tools and per-tool overrides. The levels, as in pi: `script` (default:
  reachable from scripts only), `deferred` (scripts, and named to the model), `direct` (declared
  to the model as a tool), `hidden`. `load/2` is pure apart from reading the files and never
  raises: a bad file, server or level is `{:error, reason}` naming it.
  """

  @type exposure :: :script | :deferred | :direct | :hidden
  @type transport :: {:stdio, String.t(), [String.t()]} | {:http, String.t()}
  @type server :: %{name: String.t(), transport: transport(), exposure: exposure(), tools: %{String.t() => exposure()}}

  @levels %{"script" => :script, "deferred" => :deferred, "direct" => :direct, "hidden" => :hidden}
  @word ~r/^[a-z][a-z0-9_-]{0,31}$/

  @doc "The servers of workspace `cwd`, by name. Options: `:config_home` (default `$XDG_CONFIG_HOME`, else `~/.config`)."
  @spec load(Path.t(), keyword()) :: {:ok, [server()]} | {:error, String.t()}
  def load(cwd, opts \\ []) do
    home = Keyword.get_lazy(opts, :config_home, fn -> System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config") end)

    with {:ok, user} <- file(Path.join([home, "xeito", "mcp.json"]), "the user's mcp.json"),
         {:ok, workspace} <- file(Path.join([cwd, ".xeito", "mcp.json"]), ".xeito/mcp.json") do
      {:ok, user |> Map.merge(workspace) |> Map.values() |> Enum.sort_by(& &1.name)}
    end
  end

  defp file(path, label) do
    case File.read(path) do
      {:ok, json} -> parse(json, label)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, "#{label}: #{inspect(reason)}"}
    end
  end

  @doc "The servers in a configuration file's JSON, by name, or why it cannot be read."
  @spec parse(String.t(), String.t()) :: {:ok, %{String.t() => server()}} | {:error, String.t()}
  def parse(json, label) do
    case JSON.decode(json) do
      {:ok, %{"servers" => servers}} when is_map(servers) -> servers(servers, label)
      {:ok, _other} -> {:error, "#{label}: expected {\"servers\": {...}}"}
      {:error, reason} -> {:error, "#{label}: not JSON (#{inspect(reason)})"}
    end
  end

  defp servers(servers, label) do
    Enum.reduce_while(servers, {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      case server(name, spec) do
        {:ok, server} -> {:cont, {:ok, Map.put(acc, name, server)}}
        {:error, reason} -> {:halt, {:error, "#{label}: #{reason}"}}
      end
    end)
  end

  defp server(name, spec) when is_map(spec) do
    with :ok <- name(name),
         {:ok, transport} <- transport(name, spec),
         {:ok, exposure} <- level(Map.get(spec, "exposure", "script"), "server #{name}"),
         {:ok, tools} <- tools(name, Map.get(spec, "tools", %{})) do
      {:ok, %{name: name, transport: transport, exposure: exposure, tools: tools}}
    end
  end

  defp server(name, _spec), do: {:error, "server #{name}: expected an object"}

  defp name(name) do
    if is_binary(name) and Regex.match?(@word, name),
      do: :ok,
      else: {:error, "server #{inspect(name)}: a server's name is a short lowercase word"}
  end

  defp transport(_name, %{"command" => [command | args]}) when is_binary(command), do: {:ok, {:stdio, command, args}}
  defp transport(_name, %{"url" => url}) when is_binary(url) and url != "", do: {:ok, {:http, url}}
  defp transport(name, _spec), do: {:error, "server #{name} needs a command (stdio) or a url (streamable HTTP)"}

  defp tools(name, tools) when is_map(tools) do
    Enum.reduce_while(tools, {:ok, %{}}, fn {tool, text}, {:ok, acc} ->
      case level(text, "server #{name}, tool #{tool}") do
        {:ok, exposure} -> {:cont, {:ok, Map.put(acc, tool, exposure)}}
        error -> {:halt, error}
      end
    end)
  end

  defp tools(name, _tools), do: {:error, "server #{name}: tools is an object of tool names to levels"}

  defp level(text, what) do
    case Map.fetch(@levels, text) do
      {:ok, level} -> {:ok, level}
      :error -> {:error, "#{what}: unknown exposure #{inspect(text)}; script, deferred, direct or hidden"}
    end
  end

  @doc "A tool's exposure: its own level when the server names it, else the server's."
  @spec exposure(server(), String.t()) :: exposure()
  def exposure(%{tools: tools, exposure: exposure}, tool), do: Map.get(tools, tool, exposure)
end
