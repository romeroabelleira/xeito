defmodule Xeito.Monitor do
  @moduledoc """
  Live status of the machine and its model services, for clients' status bars.

  A snapshot has three parts:

    * `system`: CPU utilisation and load, RAM, and each GPU readable from sysfs (AMD `amdgpu`:
      utilisation, VRAM, power, temperatures). `Xeito.Monitor.Host`.
    * `models`: per tier, whether its service answers and what it holds: the large tier's resident
      models with VRAM and seconds until unload (Ollama `/api/ps`), the small tier's busy slots
      (llama-server `/slots`), System One's loaded models (laya `/health`), and whether off-box
      tiers are configured. `Xeito.Monitor.Models`.
    * `queues`: `{in_use, waiting}` per tier (`Xeito.Tiers.Queue`).

  **It only polls while someone watches.** Clients subscribe (the API's `monitor` command); the
  first subscriber starts a timer (`config :xeito, :monitor_interval_ms`, default 2 s), and the
  last one to leave, or die, stops it. An idle daemon does no polling at all.
  """

  use GenServer

  alias Xeito.Monitor.Host
  alias Xeito.Monitor.Models
  alias Xeito.Tiers.Queue

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Sends `{:xeito_monitor, snapshot}` to `pid` after every poll, until it unsubscribes or exits."
  @spec subscribe(pid(), GenServer.server()) :: :ok
  def subscribe(pid \\ self(), server \\ __MODULE__), do: GenServer.call(server, {:subscribe, pid})

  @doc "Stops the updates for `pid`."
  @spec unsubscribe(pid(), GenServer.server()) :: :ok
  def unsubscribe(pid \\ self(), server \\ __MODULE__), do: GenServer.call(server, {:unsubscribe, pid})

  @doc "Whether the monitor is polling (it is exactly when it has subscribers)."
  @spec polling?(GenServer.server()) :: boolean()
  def polling?(server \\ __MODULE__), do: GenServer.call(server, :polling?)

  @impl true
  def init(opts) do
    {:ok,
     %{
       subscribers: %{},
       timer: nil,
       interval:
         Keyword.get_lazy(opts, :interval, fn ->
           Application.get_env(:xeito, :monitor_interval_ms, 2_000)
         end),
       system_opts: Keyword.get(opts, :system, []),
       models_opts: Keyword.get(opts, :models, []),
       cpu: nil
     }}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, s) do
    s =
      if Map.has_key?(s.subscribers, pid),
        do: s,
        else: %{s | subscribers: Map.put(s.subscribers, pid, Process.monitor(pid))}

    # A new subscriber gets a snapshot at once, then the regular updates.
    send(self(), :poll)
    {:reply, :ok, s}
  end

  def handle_call({:unsubscribe, pid}, _from, s), do: {:reply, :ok, drop(s, pid)}
  def handle_call(:polling?, _from, s), do: {:reply, map_size(s.subscribers) > 0, s}

  @impl true
  def handle_info(:poll, %{subscribers: subs} = s) when map_size(subs) == 0, do: {:noreply, cancel(s)}

  def handle_info(:poll, s) do
    s = cancel(s)
    {system, cpu} = Host.read(s.cpu, s.system_opts)
    snapshot = %{system: system, models: Models.read(s.models_opts), queues: queues()}
    Enum.each(Map.keys(s.subscribers), &send(&1, {:xeito_monitor, snapshot}))
    {:noreply, %{s | cpu: cpu, timer: Process.send_after(self(), :poll, s.interval)}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _}, s), do: {:noreply, drop(s, pid)}
  def handle_info(_msg, s), do: {:noreply, s}

  defp drop(s, pid) do
    case Map.pop(s.subscribers, pid) do
      {nil, _} ->
        s

      {ref, subs} ->
        Process.demonitor(ref, [:flush])
        s = %{s | subscribers: subs}
        if map_size(subs) == 0, do: cancel(s), else: s
    end
  end

  defp cancel(%{timer: nil} = s), do: s

  defp cancel(s) do
    Process.cancel_timer(s.timer)
    %{s | timer: nil}
  end

  defp queues do
    for tier <- Xeito.Tiers.all(), into: %{} do
      {in_use, waiting} = Queue.status(tier)
      {tier, %{in_use: in_use, waiting: waiting}}
    end
  end
end
