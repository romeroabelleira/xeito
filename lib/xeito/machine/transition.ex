defmodule Xeito.Machine.Transition do
  @moduledoc """
  A transition `event [guard] / action -> to`, declared inside a state with `on/2`.

  Transitions of a state are tried in declaration order, then those of its ancestors
  (events bubble up the hierarchy). The first one whose guard passes is taken.
  """

  @enforce_keys [:event, :to]
  defstruct [:event, :to, :guard, :action]

  @type t :: %__MODULE__{event: term(), to: atom(), guard: atom() | nil, action: atom() | nil}
end
