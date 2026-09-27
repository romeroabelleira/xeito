defmodule Xeito do
  @moduledoc """
  Xeito: a minimalist agent harness that runs every task as a statechart,
  asks models only for typed decisions, and logs every transition for replay
  and process mining.

  The top-level namespaces mirror the architecture sections in `docs/architecture/`:

    * `Xeito.Machine`  – versioned statechart definitions (02)
    * `Xeito.Run`      – one supervised `gen_statem` per run (02)
    * `Xeito.Decision` – typed decisions with confidence and provenance (03)
    * `Xeito.Tiers`    – decider backends: rules, small, large, openrouter, remote, human (04)
    * `Xeito.Effects`  – effect descriptions and runners (02, 10)
    * `Xeito.Log`      – the OCEL 2.0 event log (05)
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
