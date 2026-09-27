defmodule Xeito.Log.Event do
  @moduledoc """
  One event to append to the log: its OCEL type, attribute values, the exact term used for
  replay, and the objects it relates to (`{object_id, object_type, qualifier}`). Objects that do
  not exist yet are created, with attributes taken from the event's attributes of the same name.
  """

  alias Xeito.Log.Schema

  @enforce_keys [:type, :term]
  defstruct [:type, :term, attrs: %{}, objects: []]

  @type t :: %__MODULE__{
          type: String.t(),
          term: term(),
          attrs: %{optional(String.t()) => term()},
          objects: [{String.t(), String.t(), String.t()}]
        }

  @doc "Builds an event, checking the type and attribute names against the schema."
  @spec new(String.t(), term(), map(), [{String.t(), String.t(), String.t()}]) :: t()
  def new(type, term, attrs \\ %{}, objects \\ []) do
    allowed = Map.fetch!(Schema.event_types(), type)
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    case Map.keys(attrs) -- allowed do
      [] ->
        %__MODULE__{type: type, term: term, attrs: attrs, objects: objects}

      unknown ->
        raise ArgumentError, "unknown attributes #{inspect(unknown)} for event type #{type}"
    end
  end
end
