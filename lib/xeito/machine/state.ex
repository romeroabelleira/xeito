defmodule Xeito.Machine.State do
  @moduledoc "A state in a `Xeito.Machine`: leaf, compound (has children) or final."

  alias Xeito.Machine.Transition

  @enforce_keys [:name]
  defstruct [
    :name,
    :parent,
    :initial,
    :timeout,
    :entry,
    :decision,
    :decision_input,
    final: false,
    transitions: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          parent: atom() | nil,
          initial: atom() | nil,
          timeout: {pos_integer(), term()} | nil,
          entry: atom() | nil,
          decision: module() | nil,
          decision_input: atom() | nil,
          final: boolean(),
          transitions: [Transition.t()]
        }
end
