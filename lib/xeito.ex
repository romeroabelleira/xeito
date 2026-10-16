defmodule Xeito do
  @moduledoc """
  Xeito, an agent harness that runs every task as a logged statechart and asks models only for typed decisions.

  Top-level namespaces:

    * `Xeito.Machine`  – versioned statechart definitions
    * `Xeito.Run`      – one supervised `gen_statem` per run
    * `Xeito.Decision` – typed decisions with confidence and provenance
    * `Xeito.Tiers`    – the model tiers decisions escalate through
    * `Xeito.Effects`  – effect descriptions and runners
    * `Xeito.Log`      – the OCEL 2.0 event log
  """

  @namespaces [
    Xeito.Machine,
    Xeito.Run,
    Xeito.Decision,
    Xeito.Tiers,
    Xeito.Effects,
    Xeito.Log
  ]

  @doc """
  The top-level namespaces of the harness.

      iex> Xeito.namespaces() |> hd()
      Xeito.Machine
  """
  @spec namespaces() :: [module()]
  def namespaces, do: @namespaces
end
