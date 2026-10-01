defmodule Xeito.Budget do
  @moduledoc """
  Per-run ledger for resources whose limits are enforced by escalation guards: remote spend
  (`:usd`), large-model swaps (`:swaps`), and so on.

  The ledger is an ETS table keyed by the *parent* run, so every decision in a run draws on the
  same budget. It is in memory: after a node restart, budgets start from zero. The logged costs
  (`decision_made` events) remain the durable record, and `Xeito.Run.cost/2` sums them.

  Entries are removed when their run finishes (`Xeito.Run`) or their session closes
  (`Xeito.Session`). As a backstop for a long-running daemon, a periodic sweep (hourly by
  default, `config :xeito, :budget_sweep_ms`) drops entries whose owner is neither a live run
  nor a live session.
  """

  use GenServer

  @table :xeito_budget

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

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

  @doc "Removes every entry of `run_id`."
  @spec delete(String.t()) :: :ok
  def delete(run_id) do
    :ets.match_delete(@table, {{run_id, :_}, :_})
    :ok
  end

  @doc "Removes entries whose owner is neither a live run nor a live session. Returns the count."
  @spec sweep() :: non_neg_integer()
  def sweep do
    owners = @table |> :ets.select([{{{:"$1", :_}, :_}, [], [:"$1"]}]) |> Enum.uniq()
    stale = Enum.reject(owners, &alive?/1)
    Enum.each(stale, &delete/1)
    length(stale)
  end

  defp alive?(owner) do
    Xeito.Run.whereis(owner) != nil or
      (Process.whereis(Xeito.SessionRegistry) != nil and
         Registry.lookup(Xeito.SessionRegistry, owner) != [])
  end

  defp put(run_id, key, value) do
    :ets.insert(@table, {{run_id, key}, value})
    value
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, Application.get_env(:xeito, :budget_sweep_ms, 3_600_000))
end
