defmodule Xeito.Log.Codec do
  @moduledoc """
  Converts Elixir terms into JSON-safe values for OCEL attributes. This is lossy by design:
  atoms become strings, tuples become lists, and anything else is `inspect/1`-ed.
  Exact terms are kept separately in `xeito_term`.
  """

  @doc "Encodes a term as a JSON string."
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> jsonable() |> JSON.encode!()

  @doc "Converts a term to a string attribute value (`nil` stays `nil`)."
  @spec attr(term()) :: String.t() | nil
  def attr(nil), do: nil
  def attr(value) when is_binary(value), do: value
  def attr(value) when is_atom(value), do: Atom.to_string(value)
  def attr(value) when is_integer(value) or is_float(value), do: to_string(value)
  def attr(value), do: encode(value)

  @doc "Recursively converts a term into JSON-encodable data."
  @spec jsonable(term()) :: term()
  def jsonable(value) when is_boolean(value) or is_nil(value) or is_number(value), do: value
  def jsonable(value) when is_atom(value), do: Atom.to_string(value)

  def jsonable(value) when is_binary(value), do: if(String.valid?(value), do: value, else: inspect(value))

  def jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  def jsonable(value) when is_tuple(value), do: value |> Tuple.to_list() |> jsonable()

  def jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()

  def jsonable(value) when is_map(value), do: Map.new(value, fn {k, v} -> {key(k), jsonable(v)} end)

  def jsonable(value), do: inspect(value)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)
end
