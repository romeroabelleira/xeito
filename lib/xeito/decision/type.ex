defmodule Xeito.Decision.Type do
  @moduledoc """
  A compiled decision type: inputs, closed values with descriptions, rules, deciders,
  thresholds, and an optional severity order (for monotonic types such as `Risk`).
  """

  @enforce_keys [:module, :name, :version, :instructions, :values]
  defstruct [
    :module,
    :name,
    :version,
    :instructions,
    :severity,
    values: [],
    inputs: [],
    rules: [],
    deciders: [],
    min_confidence: 0.8
  ]

  @type input_spec :: %{
          name: atom(),
          max_bytes: pos_integer(),
          keep: :head | :tail,
          required: boolean()
        }
  @type rule_spec :: %{fun: atom(), then: atom() | nil}
  @type t :: %__MODULE__{
          module: module(),
          name: String.t(),
          version: String.t(),
          instructions: String.t() | nil,
          values: [{atom(), String.t()}],
          inputs: [input_spec()],
          rules: [rule_spec()],
          deciders: [atom()],
          min_confidence: float() | %{atom() => float()},
          severity: %{order: [atom()], floor: atom()} | nil
        }

  @doc "The value atoms, in declaration order (without the implicit `:abstain`)."
  @spec values(t()) :: [atom()]
  def values(%__MODULE__{values: values}), do: Enum.map(values, &elem(&1, 0))

  @doc "Maps a string produced by a model back to one of the type's values."
  @spec cast(t(), String.t() | atom()) :: {:ok, atom()} | :error
  def cast(type, value) when is_atom(value),
    do: if(value in values(type), do: {:ok, value}, else: :error)

  def cast(type, value) when is_binary(value) do
    case Enum.find(values(type), &(Atom.to_string(&1) == value)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  @doc "The confidence threshold for a tier."
  @spec threshold(t(), atom()) :: float()
  def threshold(%__MODULE__{min_confidence: t}, _tier) when is_number(t), do: t
  def threshold(%__MODULE__{min_confidence: map}, tier), do: Map.get(map, tier, 0.8)

  @doc """
  Normalises an input map: keeps the declared inputs (as strings), truncates them
  deterministically to `max_bytes`, and raises if a required input is missing.
  """
  @spec normalize_input(t(), map()) :: %{atom() => String.t()}
  def normalize_input(%__MODULE__{inputs: specs}, input) do
    Map.new(specs, fn spec ->
      raw = Map.get(input, spec.name, Map.get(input, Atom.to_string(spec.name)))

      if is_nil(raw) and spec.required,
        do: raise(ArgumentError, "missing required input #{inspect(spec.name)}")

      {spec.name, raw |> to_text() |> truncate(spec)}
    end)
  end

  @doc "A stable hash of the type version and normalised input (cache and replay key)."
  @spec input_hash(t(), map()) :: String.t()
  def input_hash(type, normalized) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({type.name, type.version, Enum.sort(normalized)})
    )
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp to_text(nil), do: ""
  defp to_text(text) when is_binary(text), do: text
  defp to_text(other), do: inspect(other)

  defp truncate(text, %{max_bytes: max}) when byte_size(text) <= max, do: text
  defp truncate(text, %{max_bytes: max, keep: :head}), do: valid_utf8(binary_part(text, 0, max))

  defp truncate(text, %{max_bytes: max, keep: :tail}),
    do: valid_utf8(binary_part(text, byte_size(text) - max, max))

  defp valid_utf8(bin),
    do: bin |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
end
