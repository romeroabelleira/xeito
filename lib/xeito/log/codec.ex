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
  def jsonable(value) when is_map(value) or is_list(value) or is_tuple(value), do: container(value)
  def jsonable(value), do: scalar(value)

  defp container(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()
  defp container(map) when is_map(map), do: Map.new(map, fn {k, v} -> {key(k), jsonable(v)} end)
  defp container(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp container(tuple), do: tuple |> Tuple.to_list() |> jsonable()

  defp scalar(value) when is_number(value) or value in [true, false, nil], do: value
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(value) when is_binary(value), do: if(String.valid?(value), do: value, else: inspect(value))
  defp scalar(value), do: inspect(value)

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: inspect(k)
end
