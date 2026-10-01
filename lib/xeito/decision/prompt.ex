defmodule Xeito.Decision.Prompt do
  @moduledoc """
  Renders a decision type and a normalised input for each backend:

    * `messages/2` — system and user chat messages for generative tiers
    * `json_schema/1` — `{"value": enum}`, for grammar-constrained decoding (llama.cpp,
      Ollama `format`, Anthropic tool input schemas)
    * `system_one/3` — a Jev-compatible `/v1/systemone` request with one `choice` question

  The value always comes first and there is no rationale field: bench 0 measured a rationale
  costing ~4× the decision itself on the CPU tier.
  """

  alias Xeito.Decision.Type

  @doc "Chat messages for a generative tier."
  @spec messages(Type.t(), map()) :: [map()]
  def messages(%Type{} = type, input) do
    options = Enum.map_join(type.values, "\n", fn {value, desc} -> "- #{value}: #{desc}" end)

    system = """
    You make one typed decision.
    Decision: #{type.instructions}
    Options:
    #{options}
    Answer with JSON only: {"value": "<one of the options>"}\
    """

    [%{role: "system", content: system}, %{role: "user", content: render_input(type, input)}]
  end

  @doc "The input as `name: value` lines, in declaration order."
  @spec render_input(Type.t(), map()) :: String.t()
  def render_input(%Type{inputs: specs}, input) do
    Enum.map_join(specs, "\n", fn spec -> "#{spec.name}: #{Map.get(input, spec.name, "")}" end)
  end

  @doc "JSON Schema of the decision's output."
  @spec json_schema(Type.t()) :: map()
  def json_schema(%Type{} = type) do
    %{
      "type" => "object",
      "properties" => %{
        "value" => %{"type" => "string", "enum" => Enum.map(Type.values(type), &Atom.to_string/1)}
      },
      "required" => ["value"],
      "additionalProperties" => false
    }
  end

  @doc "A `/v1/systemone` request body with one `choice` question named after the type."
  @spec system_one(Type.t(), map(), String.t() | nil) :: map()
  def system_one(%Type{} = type, input, model) do
    body = %{
      "state" => Map.new(input, fn {k, v} -> {Atom.to_string(k), v} end),
      "questions" => %{
        type.name => %{
          "type" => "choice",
          "instructions" => type.instructions,
          "criteria" => Map.new(type.values, fn {value, desc} -> {Atom.to_string(value), desc} end)
        }
      }
    }

    if model, do: Map.put(body, "model", model), else: body
  end
end
