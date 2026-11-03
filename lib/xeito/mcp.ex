defmodule Xeito.Mcp do
  @moduledoc """
  The MCP tools a workspace's servers offer, as the model and the scripts see them.

    * `tools/2`: the tools of the workspace's servers (`Xeito.Mcp.Servers`) with their
      exposure, `hidden` ones left out; a configuration error gives none.
    * `direct/1`: the tools declared to the model; `deferred/1`: those named to it, for scripts.
    * `allowed?/2`: whether the policy lets a tool be called: an open-world tool
      (`Xeito.Mcp.Tool.open_world?/1`) counts as off-box, and needs the policy's `network`
      setting (`Xeito.Policy`) not to be `:forbidden`, as `fetch` does.
    * `prompt_section/2`: the lines of the system prompt that name the deferred tools, and the
      configuration's error when there is one.
  """

  alias Xeito.Mcp.Config
  alias Xeito.Mcp.Servers
  alias Xeito.Mcp.Tool

  @type tool :: Servers.tool()

  @doc "The workspace's tools that are not hidden, and the configuration's error, if any."
  @spec tools(Path.t(), keyword()) :: {[tool()], String.t() | nil}
  def tools(cwd, opts \\ []) do
    # A workspace with no servers configured starts no process.
    with {:ok, [_ | _]} <- Config.load(cwd, opts),
         {:ok, tools} <- Servers.tools(cwd, opts) do
      {Enum.reject(tools, &(&1.exposure == :hidden)), nil}
    else
      {:ok, []} -> {[], nil}
      {:error, reason} -> {[], reason}
    end
  end

  @doc "The tools declared to the model as its own."
  @spec direct([tool()]) :: [tool()]
  def direct(tools), do: Enum.filter(tools, &(&1.exposure == :direct))

  @doc "The tools named to the model, reachable from scripts."
  @spec deferred([tool()]) :: [tool()]
  def deferred(tools), do: Enum.filter(tools, &(&1.exposure == :deferred))

  @doc "Whether the policy's `network` setting lets `tool` be called: an open-world tool is off-box."
  @spec allowed?(tool() | Tool.t(), term()) :: boolean()
  def allowed?(tool, network), do: network != :forbidden or not Tool.open_world?(tool)

  @doc "Why `tool` may not be called under `network`, or `nil`."
  @spec refusal(tool() | Tool.t(), term()) :: String.t() | nil
  def refusal(tool, network) do
    if allowed?(tool, network),
      do: nil,
      else:
        "refused: #{Tool.model_name(tool)} reaches outside this machine (an open-world tool), and the " <>
          "policy's network setting is forbidden"
  end

  @doc "The system prompt's lines for the deferred tools (one each, `server.tool: description`) and a configuration error."
  @spec prompt_section([tool()], String.t() | nil) :: String.t()
  def prompt_section(tools, error) do
    lines =
      for tool <- deferred(tools),
          do: "- #{tool.server}.#{tool.name}: #{tool.description}"

    named =
      if lines == [],
        do: "",
        else: "\n\nMCP tools reachable from scripts (Script.mcp(server, tool, args)):\n" <> Enum.join(lines, "\n") <> "\n"

    named <> if(error, do: "\n\n(MCP servers not available: #{error})\n", else: "")
  end
end
