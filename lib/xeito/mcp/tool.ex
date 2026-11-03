defmodule Xeito.Mcp.Tool do
  @moduledoc """
  An MCP server's tool as Xeito sees it: `%{server, name, description, schema, annotations}`,
  from a `tools/list` entry (`from_listing/2`).

    * `risk/1`: what the annotations let the rules decide, as for a command: read-only and
      closed-world (`readOnlyHint` true, `openWorldHint` false) is `:safe`; anything else,
      destructive or unsaid, is `:review`.
    * `open_world?/1`: a tool that reaches outside its server (`openWorldHint`, true when
      unsaid), which the data-locality policy treats as off-box.
    * `model_name/1` and `parse_model_name/1`: the name a direct tool has for the model,
      `server__tool`; `spec/1`, its function spec; `search/2`, the tools matching a query
      (`Xeito.Skills.Index`'s BM25 search); `text/1`, a result's text for the model and scripts.
  """

  alias Xeito.Skills.Index

  @type t :: %{server: String.t(), name: String.t(), description: String.t(), schema: map(), annotations: map()}

  @doc "A tool from its `tools/list` entry on `server`."
  @spec from_listing(String.t(), map()) :: t()
  def from_listing(server, %{"name" => name} = listed) do
    %{
      server: server,
      name: name,
      description: Map.get(listed, "description") || "",
      schema: Map.get(listed, "inputSchema") || %{"type" => "object"},
      annotations: Map.get(listed, "annotations") || %{}
    }
  end

  @doc "What the rules decide from the annotations: `:safe` for a read-only, closed-world tool, else `:review`."
  @spec risk(t()) :: :safe | :review
  def risk(%{annotations: %{"readOnlyHint" => true, "openWorldHint" => false}}), do: :safe
  def risk(_tool), do: :review

  @doc "Whether the tool reaches outside its server's world (true when the server does not say)."
  @spec open_world?(t()) :: boolean()
  def open_world?(%{annotations: annotations}), do: Map.get(annotations, "openWorldHint", true) == true

  @doc "The tool's name for the model: `server__tool`."
  @spec model_name(t()) :: String.t()
  def model_name(%{server: server, name: name}), do: server <> "__" <> name

  @doc "The server and tool of a model-facing name, or `:error` for another tool's name."
  @spec parse_model_name(String.t()) :: {:ok, {String.t(), String.t()}} | :error
  def parse_model_name(name) do
    case String.split(name, "__", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {:ok, {server, tool}}
      _ -> :error
    end
  end

  @doc "An OpenAI-style function spec for a direct tool (`Xeito.Tools.specs/1`)."
  @spec spec(t()) :: map()
  def spec(tool),
    do: %{type: "function", function: %{name: model_name(tool), description: tool.description, parameters: tool.schema}}

  @doc "The tools matching `query`, best first, at most `k` (default 5)."
  @spec search([t()], String.t(), pos_integer()) :: [t()]
  def search(tools, query, k \\ 5) do
    as_skills = Enum.map(tools, &%{name: &1.name, description: &1.description, keywords: [&1.server], examples: []})
    found = Index.search(as_skills, query, k: k, any: true)
    Enum.map(found, fn skill -> Enum.find(tools, &(&1.name == skill.name and skill.keywords == [&1.server])) end)
  end

  @doc "A tool result's text: its text content, one piece per line (other content named by type), or its structured content as JSON."
  @spec text(map()) :: String.t()
  def text(%{"content" => [_ | _] = content}), do: Enum.map_join(content, "\n", &piece/1)
  def text(%{"structuredContent" => structured}) when is_map(structured), do: JSON.encode!(structured)
  def text(_result), do: ""

  defp piece(%{"type" => "text", "text" => text}), do: text
  defp piece(%{"type" => type}), do: "[#{type}]"
  defp piece(_other), do: "[content]"
end
