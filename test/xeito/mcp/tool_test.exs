defmodule Xeito.Mcp.ToolTest do
  use ExUnit.Case, async: true

  alias Xeito.Mcp.Tool

  defp tool(annotations, name \\ "t"),
    do: %{server: "s", name: name, description: "does #{name}", schema: %{"type" => "object"}, annotations: annotations}

  test "risk/1 from the annotations: read-only and closed-world is safe by rule; anything else goes to review" do
    assert Tool.risk(tool(%{"readOnlyHint" => true, "openWorldHint" => false})) == :safe
    assert Tool.risk(tool(%{"readOnlyHint" => true})) == :review
    assert Tool.risk(tool(%{"readOnlyHint" => true, "openWorldHint" => true})) == :review
    assert Tool.risk(tool(%{"readOnlyHint" => false, "openWorldHint" => false})) == :review
    assert Tool.risk(tool(%{"destructiveHint" => true})) == :review
    assert Tool.risk(tool(%{})) == :review
  end

  test "open_world?/1: a tool that reaches outside the server's own world, or does not say" do
    assert Tool.open_world?(tool(%{"openWorldHint" => true}))
    assert Tool.open_world?(tool(%{}))
    refute Tool.open_world?(tool(%{"openWorldHint" => false}))
  end

  test "from_listing/2 reads a server's tools/list entry; the model's name for a tool joins server and tool" do
    listed = %{
      "name" => "echo",
      "description" => "Echoes",
      "inputSchema" => %{"type" => "object"},
      "annotations" => %{"readOnlyHint" => true}
    }

    assert %{
             server: "fx",
             name: "echo",
             description: "Echoes",
             schema: %{"type" => "object"},
             annotations: %{"readOnlyHint" => true}
           } = tool = Tool.from_listing("fx", listed)

    assert Tool.model_name(tool) == "fx__echo"

    assert Tool.from_listing("fx", %{"name" => "bare"}) == %{
             server: "fx",
             name: "bare",
             description: "",
             schema: %{"type" => "object"},
             annotations: %{}
           }

    assert {:ok, {"fx", "echo"}} = Tool.parse_model_name("fx__echo")
    assert :error = Tool.parse_model_name("read")
    assert :error = Tool.parse_model_name("__echo")
    assert :error = Tool.parse_model_name("fx__")
  end

  test "spec/1: an OpenAI-style function spec for a direct tool" do
    assert %{type: "function", function: %{name: "s__t", description: "does t", parameters: %{"type" => "object"}}} =
             Tool.spec(tool(%{}))
  end

  test "search/2: the tools matching a query, best first, by name, description and server" do
    tools = [
      %{} |> tool("echo") |> Map.put(:description, "Echoes the text it is given"),
      %{} |> tool("lookup") |> Map.put(:description, "Looks a word up on the web"),
      %{} |> tool("wipe") |> Map.put(:description, "Wipes a target")
    ]

    assert [%{name: "lookup"}] = Tool.search(tools, "look up a word")
    assert [%{name: "echo"}] = Tool.search(tools, "echo")
    assert Tool.search(tools, "nothing matches here") == []
  end

  test "text/1: a tool result's text content, for the model and for scripts" do
    assert Tool.text(%{
             "content" => [
               %{"type" => "text", "text" => "a"},
               %{"type" => "image", "data" => "x"},
               %{"type" => "text", "text" => "b"}
             ]
           }) ==
             "a\n[image]\nb"

    assert Tool.text(%{"content" => [%{"text" => "no type"}]}) == "[content]"
    assert Tool.text(%{"content" => []}) == ""
    assert Tool.text(%{"structuredContent" => %{"n" => 1}, "content" => []}) == ~s({"n":1})
  end
end
