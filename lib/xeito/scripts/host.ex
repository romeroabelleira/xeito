defmodule Xeito.Scripts.Host do
  @moduledoc """
  The process that holds a session's script sandbox VM (`Xeito.Scripts.Sandbox`): one per
  session, started by the session's first script and reused by the next, so the VM's start-up is
  paid once.

    * `eval/5` evaluates a script in the session's sandbox, starting the host and the VM when
      there is none, and runs one script at a time per session.
    * A VM that died is replaced by the next script; `stop/1` ends the host and its VM, and a
      host idle for `@idle_ms` ends itself.
  """

  use GenServer

  alias Xeito.Scripts.Sandbox

  @idle_ms 600_000
  @registry Xeito.Scripts.HostRegistry
  @supervisor Xeito.Scripts.HostSupervisor

  @doc "Starts the host of `session`, registered by it. Options: `:idle_ms` (default 10 minutes)."
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(session, opts \\ []),
    do: GenServer.start_link(__MODULE__, {session, Keyword.get(opts, :idle_ms, @idle_ms)}, name: via(session))

  @doc "Evaluates `code` in the sandbox of `session` (`Xeito.Scripts.Sandbox.eval/5`); the outcome and the accumulator."
  @spec eval(String.t(), String.t(), map(), term(), (String.t(), [term()], term() -> {term(), term()})) ::
          {Xeito.Scripts.Vm.outcome(), term()}
  def eval(session, code, limits, acc, on_call),
    do: GenServer.call(find_or_start(session), {:eval, code, limits, acc, on_call}, :infinity)

  @doc "The host of `session`, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session) do
    # The registry forgets a stopped host a moment after it is gone.
    case Registry.lookup(@registry, session) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "Stops the host of `session` and its VM, if there is one."
  @spec stop(String.t()) :: :ok
  def stop(session) do
    case whereis(session) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  defp find_or_start(session) do
    spec = %{id: __MODULE__, start: {__MODULE__, :start_link, [session]}, restart: :temporary}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp via(session), do: {:via, Registry, {@registry, session}}

  @impl true
  def init({session, idle_ms}) do
    # The VM is linked: its exit is a message here, not the host's end.
    Process.flag(:trap_exit, true)
    {:ok, %{session: session, sandbox: nil, idle_ms: idle_ms}, idle_ms}
  end

  @impl true
  def handle_call({:eval, code, limits, acc, on_call}, _from, state) do
    case sandbox(state) do
      {:ok, sandbox} ->
        {outcome, sandbox, acc} = Sandbox.eval(sandbox, code, limits, acc, on_call)
        {:reply, {outcome, acc}, %{state | sandbox: sandbox}, state.idle_ms}

      {:error, reason} ->
        failure = %{type: :crashed, message: "the sandbox could not start: #{inspect(reason)}", stdio: ""}
        {:reply, {{:error, failure}, acc}, state, state.idle_ms}
    end
  end

  defp sandbox(%{sandbox: nil}), do: Sandbox.start()
  defp sandbox(%{sandbox: sandbox}), do: {:ok, sandbox}

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}
  # The VM ended between scripts (or an old one's last breath): the next script starts a new one.
  def handle_info({:EXIT, pid, _reason}, %{sandbox: %{pid: pid}} = state),
    do: {:noreply, %{state | sandbox: nil}, state.idle_ms}

  def handle_info(_stray_output_or_exit, state), do: {:noreply, state, state.idle_ms}

  @impl true
  def terminate(_reason, %{sandbox: %{} = sandbox}), do: Sandbox.stop(sandbox)
  def terminate(_reason, _state), do: :ok
end
