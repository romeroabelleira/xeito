defmodule Xeito.Skills.Examples.Worker do
  @moduledoc """
  Writes missing example requests in the daemon's background (P4f step 4): the user's skills
  when it starts, and the skills each chat turn sees (`wanted/2`), one model call at a time, as
  background calls on the local tier (`Xeito.Skills.Examples.refresh/3`). A turn never waits for
  it: a skill without examples is found by its name, keywords and description until they exist.

  Without a local tier it does nothing.
  """

  use GenServer

  alias Xeito.Skills
  alias Xeito.Skills.Examples
  alias Xeito.Tiers

  @doc """
  Options: `:name` (default this module; `nil` for none), `:cfg` (the local tier's
  configuration; default `Xeito.Tiers.config(:local)`), `:dir` and `:log` (as for
  `Xeito.Skills.Examples.refresh/3`), `:startup` (the skills to write first; default the user's).
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Asks for the examples of `skills` to be written, if they are missing or stale. Without a worker, nothing happens."
  @spec wanted(GenServer.server(), [Skills.t()]) :: :ok
  def wanted(worker \\ __MODULE__, skills), do: GenServer.cast(worker, {:wanted, skills})

  @doc "Waits until the worker has written everything asked of it (for tests)."
  @spec idle(GenServer.server()) :: :ok
  def idle(worker \\ __MODULE__), do: GenServer.call(worker, :idle, :infinity)

  @impl true
  def init(opts) do
    cfg = Keyword.get_lazy(opts, :cfg, fn -> Tiers.config(:local) end)
    refresh = Keyword.take(opts, [:dir, :log])
    startup = Keyword.get_lazy(opts, :startup, fn -> Skills.from_dirs([Skills.user_dir()]) end)
    {:ok, %{cfg: cfg, refresh: refresh}, {:continue, {:wanted, startup}}}
  end

  @impl true
  def handle_continue({:wanted, skills}, state), do: {:noreply, write(skills, state)}

  @impl true
  def handle_cast({:wanted, skills}, state), do: {:noreply, write(skills, state)}

  @impl true
  def handle_call(:idle, _from, state), do: {:reply, :ok, state}

  defp write(_skills, %{cfg: nil} = state), do: state

  defp write(skills, state) do
    Examples.refresh(skills, state.cfg, state.refresh)
    state
  end
end
