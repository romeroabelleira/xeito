defmodule Xeito.Tiers.Queue do
  @moduledoc """
  Per-backend capacity limits. Each tier admits at most `capacity` concurrent calls; further
  callers wait in FIFO order.

  Bench 1 measured why this matters: `laya-serve` serialises requests (~16 decisions/s whatever
  the concurrency), llama-server has a few parallel slots, and a GPU generation competes with
  itself. Capacities come from `config :xeito, :tier_capacity` (defaults below).
  """

  use GenServer

  @defaults %{rules: :infinity, system_one: 1, small: 4, large: 1, openrouter: 4, remote: 4}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Runs `fun` once a slot for `tier` is free. Returns `fun`'s result."
  @spec run(atom(), (-> result), timeout()) :: result when result: term()
  def run(tier, fun, timeout \\ :infinity) do
    case capacity(tier) do
      :infinity ->
        fun.()

      _ ->
        :ok = GenServer.call(__MODULE__, {:acquire, tier}, timeout)

        try do
          fun.()
        after
          GenServer.cast(__MODULE__, {:release, tier, self()})
        end
    end
  end

  @doc "The configured capacity of a tier."
  @spec capacity(atom()) :: pos_integer() | :infinity
  def capacity(tier) do
    configured = Application.get_env(:xeito, :tier_capacity, %{})
    Map.get(configured, tier, Map.get(@defaults, tier, 1))
  end

  @doc "Current `{in_use, waiting}` for a tier (diagnostics)."
  @spec status(atom()) :: {non_neg_integer(), non_neg_integer()}
  def status(tier), do: GenServer.call(__MODULE__, {:status, tier})

  @impl true
  def init(:ok), do: {:ok, %{in_use: %{}, waiting: %{}, holders: %{}}}

  @impl true
  def handle_call({:acquire, tier}, {pid, _} = from, state) do
    in_use = Map.get(state.in_use, tier, 0)

    if in_use < capacity(tier) do
      {:reply, :ok, grant(state, tier, pid)}
    else
      waiting = Map.update(state.waiting, tier, :queue.from_list([from]), &:queue.in(from, &1))
      {:noreply, %{state | waiting: waiting}}
    end
  end

  def handle_call({:status, tier}, _from, state) do
    waiting = state.waiting |> Map.get(tier, :queue.new()) |> :queue.len()
    {:reply, {Map.get(state.in_use, tier, 0), waiting}, state}
  end

  @impl true
  def handle_cast({:release, tier, pid}, state), do: {:noreply, release(state, tier, pid)}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case Map.pop(state.holders, ref) do
      {{^pid, tier}, holders} -> {:noreply, next(%{state | holders: holders}, tier)}
      {nil, _} -> {:noreply, state}
    end
  end

  defp grant(state, tier, pid) do
    ref = Process.monitor(pid)

    %{
      state
      | in_use: Map.update(state.in_use, tier, 1, &(&1 + 1)),
        holders: Map.put(state.holders, ref, {pid, tier})
    }
  end

  defp release(state, tier, pid) do
    case Enum.find(state.holders, fn {_ref, holder} -> holder == {pid, tier} end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        next(%{state | holders: Map.delete(state.holders, ref)}, tier)

      nil ->
        state
    end
  end

  # A slot was freed: hand it to the next waiter, or decrement.
  defp next(state, tier) do
    state = %{state | in_use: Map.update(state.in_use, tier, 0, &max(&1 - 1, 0))}

    case :queue.out(Map.get(state.waiting, tier, :queue.new())) do
      {{:value, {pid, _} = from}, rest} ->
        GenServer.reply(from, :ok)
        grant(%{state | waiting: Map.put(state.waiting, tier, rest)}, tier, pid)

      {:empty, _} ->
        state
    end
  end
end
