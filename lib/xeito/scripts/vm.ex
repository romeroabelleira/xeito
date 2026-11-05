defmodule Xeito.Scripts.Vm do
  @moduledoc """
  The script sandbox: evaluates a script with Dune under `Xeito.Scripts.Allowlist` and answers its
  calls to the outside through whoever runs it.

    * `run/3` evaluates `code` in a Dune process with `limits` (`reductions`, `heap` in words,
      `timeout_ms`; by default 100 M, 50 M and 600 000, enough to read and shape a few megabytes
      of text and little enough to stop a runaway loop within seconds) and serves every
      `Xeito.Scripts.Api` call the script makes with `on_call.(name, args)`, in order, while
      the evaluation runs. It returns the script's last value, or why it failed.
    * `main/0` is the entry point of the separate VM `Xeito.Scripts.Sandbox` starts: it speaks
      `Xeito.Scripts.Protocol` on stdin and stdout and serves calls by asking the daemon, and
      halts when the stream ends or the daemon's OS pid (`-xeito_parent`) is gone
      (`watch_parent/3`), so a daemon killed outright leaves no VM behind.

  A script that fails any way (a restricted call, the reductions, memory or time limits, an
  exception, a syntax error, or a call the runner refused) is reported, never raised, and the VM
  logs nothing: its stdout is the protocol, and a crash report of a script's exception would be
  formatted inside the limited process.
  """

  alias Xeito.Scripts.Allowlist
  alias Xeito.Scripts.Protocol

  @name :xeito_scripts_vm
  # Sized for a few megabytes of text: a regex pass over 3 MB of logs costs under 64 M reductions
  # and 4 M words; a runaway loop or an unbounded list still stops within a second or two.
  @default_limits %{"reductions" => 100_000_000, "heap" => 50_000_000, "timeout_ms" => 600_000}

  @type failure :: %{type: atom(), message: String.t(), stdio: String.t()}
  @type outcome :: {:ok, term(), String.t()} | {:error, failure()}

  @doc "Evaluates `code` under `limits`, serving its calls with `on_call`; the last value and the script's stdio, or the failure."
  @spec run(String.t(), map(), (String.t(), [term()] -> term())) :: outcome()
  def run(code, limits, on_call) do
    limits = Map.merge(@default_limits, limits)
    preload()
    Process.register(self(), @name)

    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        send(
          parent,
          {:evaluated, self(),
           Dune.eval_string(code,
             allowlist: Allowlist,
             max_reductions: limits["reductions"],
             max_heap_size: limits["heap"],
             timeout: limits["timeout_ms"],
             # Parsing is quick; the default of 50 ms fails under load.
             parse_timeout: 5_000,
             atom_pool_size: 5_000
           )}
        )
      end)

    serve({pid, ref}, on_call)
  after
    Process.unregister(@name)
  end

  @doc """
  Loads every module a script may call, with the atoms of their aliases, so a fresh VM resolves
  them from its first script: Dune's parser creates no atoms, so it maps a name that does not
  exist yet (a function no loaded module exports, an alias no loaded module names) to a private
  one, and the call fails as undefined.
  """
  @spec preload() :: :ok
  def preload do
    modules = [Script, Xeito.Scripts.Api, Dune.Allowlist.Default | Application.spec(:elixir, :modules)]
    Code.ensure_all_loaded!(modules)

    modules
    |> Enum.flat_map(fn module -> module |> Atom.to_string() |> String.split(".") end)
    |> Enum.each(&String.to_atom/1)
  end

  # Calls arrive while the evaluation runs; the evaluator's result ends the loop.
  defp serve({pid, ref} = evaluator, on_call) do
    receive do
      {:call, from, name, args} ->
        send(from, {:reply, on_call.(name, args)})
        serve(evaluator, on_call)

      {:evaluated, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        outcome(result)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, %{type: :exception, message: "the evaluation stopped: #{inspect(reason)}", stdio: ""}}
    end
  end

  defp outcome(%Dune.Success{value: value, stdio: stdio}), do: {:ok, value, stdio}

  defp outcome(%Dune.Failure{type: type, message: message, stdio: stdio}),
    do: {:error, %{type: type, message: message, stdio: stdio}}

  @doc "A script's call to the outside (`Xeito.Scripts.Api`): asks the running `run/3` and waits for its answer."
  @spec call(String.t(), [term()]) :: term()
  def call(name, args) do
    send(Process.whereis(@name) || raise("no script is running"), {:call, self(), name, args})

    receive do
      {:reply, value} -> value
    end
  end

  @doc """
  The separate VM's entry point: `ready`, then one `run` message at a time from `device` (stdin),
  calls and the outcome back on it; ends when the daemon closes the stream.
  """
  @watch_ms 2_000

  @spec main() :: no_return()
  def main do
    # Nothing is logged here: a crash report of a script's exception would be formatted inside the
    # limited process, where a large value in it costs the heap or the reductions, and printed
    # on stdout, which carries the protocol.
    :logger.set_primary_config(:level, :none)
    watch(:init.get_argument(:xeito_parent))
    main(:stdio)
  end

  # Halts this VM once the daemon that started it (`-xeito_parent <os pid>`) is gone.
  defp watch({:ok, [[parent]]}), do: spawn(fn -> watch_parent(to_string(parent), @watch_ms, &halt/0) end)
  defp watch(_none), do: :ok

  @spec main(IO.device()) :: no_return()
  def main(device) do
    serve_stream(device)
    halt()
  end

  @spec halt() :: no_return()
  defp halt, do: System.halt(0)

  @doc "Calls `on_gone` once OS process `os_pid` no longer exists, checking every `interval` ms."
  @spec watch_parent(String.t(), pos_integer(), (-> term())) :: term()
  def watch_parent(os_pid, interval, on_gone) do
    if parent_alive?(os_pid) do
      Process.sleep(interval)
      watch_parent(os_pid, interval, on_gone)
    else
      on_gone.()
    end
  end

  @doc "Whether OS process `os_pid` exists (`kill -0`)."
  @spec parent_alive?(String.t()) :: boolean()
  def parent_alive?(os_pid), do: match?({_, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))

  @doc "Serves `run` messages from `device` until it ends: what `main/1` does, without halting."
  @spec serve_stream(IO.device()) :: :eof
  def serve_stream(device) do
    write(device, %{t: "ready"})
    loop(device)
  end

  defp loop(device) do
    case IO.gets(device, "") do
      line when is_binary(line) ->
        line |> Protocol.decode() |> handle(device)
        loop(device)

      _eof_or_error ->
        :eof
    end
  end

  defp handle({:ok, %{"t" => "run", "id" => id, "code" => code} = message}, device) do
    on_call = fn name, args -> ask(device, id, name, args) end

    case run(code, message["limits"] || %{}, on_call) do
      {:ok, value, stdio} -> write(device, %{t: "done", id: id, value: Protocol.jsonable(value), stdio: stdio})
      {:error, failure} -> write(device, Map.merge(%{t: "failed", id: id}, failure))
    end
  end

  defp handle(_other, device),
    do: write(device, %{t: "failed", id: nil, type: "protocol", message: "not a run message", stdio: ""})

  # One call: written out, its reply read back on the next line; a stream that ends mid-call ends the VM.
  defp ask(device, run_id, name, args) do
    write(device, %{t: "call", id: run_id, name: name, args: args})

    with line when is_binary(line) <- IO.gets(device, ""),
         {:ok, %{"t" => "reply", "value" => value}} <- Protocol.decode(line) do
      value
    else
      {:ok, _other} -> %{"ok" => false, "error" => "the runner sent no reply"}
      _ended -> exit(:normal)
    end
  end

  defp write(device, message), do: IO.write(device, Protocol.encode(message))
end
