defmodule Xeito.Budget do
  @moduledoc """
  Per-run ledger for resources whose limits are enforced by escalation guards: remote spend
  (`:usd`), large-model swaps (`:swaps`), and so on.

  The ledger is an ETS table keyed by the *parent* run, so every decision in a run draws on the
  same budget. It is in memory: after a node restart, budgets start from zero. The logged costs
  (`decision_made` events) remain the durable record, and `Xeito.Run.cost/2` sums them.
  """

  use GenServer

  @table :xeito_budget

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Adds `amount` to `key` for `run_id`. Returns the new total."
  @spec add(String.t(), atom(), number()) :: number()
  def add(run_id, key, amount) do
    if is_integer(amount),
      do: :ets.update_counter(@table, {run_id, key}, amount, {{run_id, key}, 0}),
      else: put(run_id, key, get(run_id, key) + amount)
  end

  @doc "The current total of `key` for `run_id` (0 if never used)."
  @spec get(String.t(), atom()) :: number()
  def get(run_id, key) do
    case :ets.lookup(@table, {run_id, key}) do
      [{_, value}] -> value
      [] -> 0
    end
  end

  defp put(run_id, key, value) do
    :ets.insert(@table, {{run_id, key}, value})
    value
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end
end
