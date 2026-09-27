defmodule Xeito.RunSupervisor do
  @moduledoc """
  Dynamic supervisor with one transient child per run. A crashed run is restarted with the same
  `run_id` and recovers from the log; a run that reached a final state is not restarted.
  """

  use DynamicSupervisor

  alias Xeito.Run

  @doc false
  def start_link(opts),
    do: DynamicSupervisor.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok),
    do: DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 5)

  @doc """
  Starts a run of `machine` with `input`. Options: `:run_id` (generated if absent), `:log`,
  `:runner`, `:debug` (step mode and breakpoints, see `Xeito.Run.debug/2`), `:supervisor`.
  Returns `{:ok, run_id}`.
  """
  @spec start_run(module(), map(), keyword()) :: {:ok, Run.run_id()} | {:error, term()}
  def start_run(machine, input, opts \\ []) do
    run_id = Keyword.get_lazy(opts, :run_id, &new_run_id/0)
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)

    child_opts =
      [run_id: run_id, machine: machine, input: input] ++
        Keyword.take(opts, [:log, :runner, :debug])

    case DynamicSupervisor.start_child(supervisor, {Run, child_opts}) do
      {:ok, _pid} -> {:ok, run_id}
      :ignore -> {:ok, run_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Resumes a logged run that is not running (for example after a node restart)."
  @spec resume_run(module(), Run.run_id(), keyword()) :: {:ok, Run.run_id()} | {:error, term()}
  def resume_run(machine, run_id, opts \\ []),
    do: start_run(machine, %{}, Keyword.put(opts, :run_id, run_id))

  defp new_run_id,
    do: "run-" <> Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false)
end
