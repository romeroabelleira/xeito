defmodule Xeito.Scripts.Sandbox do
  @moduledoc """
  A script sandbox VM of its own: a small Erlang VM started through erlexec with this release's
  code, running `Xeito.Scripts.Vm.main/0`, that holds no credentials, is not a distributed node
  and reaches the daemon only through `Xeito.Scripts.Protocol` on its stdin and stdout. It is
  told the daemon's OS pid and halts on its own once the daemon is gone.

    * `start/1` starts the VM and waits for `ready`; `stop/1` ends it with its process group.
    * `eval/5` sends a script with its limits and serves every call the script makes with
      `on_call.(name, args, acc)`, which gives the value and the next accumulator, until the
      outcome comes back: the last value and the script's stdio, or the failure, with the
      accumulator. A VM that stops or stays silent past `timeout_ms` is killed, and the outcome
      is a `timeout` or `crashed` failure.

  One sandbox per session is the intended use: its start-up is paid once.
  """

  alias Xeito.Scripts.Protocol
  alias Xeito.Scripts.Vm

  @type t :: %{pid: pid(), os_pid: non_neg_integer(), buffer: String.t()}

  @doc "Starts the VM and waits for it to be ready (at most `opts[:start_timeout]` ms, default 15 000)."
  @spec start(keyword()) :: {:ok, t()} | {:error, term()}
  def start(opts \\ []) do
    erl = Path.join([to_string(:code.root_dir()), "bin", "erl"])
    paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    # The VM is told the daemon's OS pid, so it halts when the daemon is gone (`Xeito.Scripts.Vm.watch_parent/3`).
    args =
      ["-noshell", "-elixir", "ansi_enabled", "false", "-xeito_parent", System.pid()] ++ paths ++ ["-eval", eval_main()]

    case :exec.run_link(Enum.map([erl | args], &to_charlist/1), [:stdin, :stdout, :stderr, {:group, 0}, :kill_group]) do
      {:ok, pid, os_pid} ->
        sandbox = %{pid: pid, os_pid: os_pid, buffer: ""}

        case receive_message(sandbox, Keyword.get(opts, :start_timeout, 15_000)) do
          {:ok, %{"t" => "ready"}, sandbox} -> {:ok, sandbox}
          {:ok, other, _} -> stop_with(sandbox, {:error, {:unexpected, other}})
          {:error, reason} -> stop_with(sandbox, {:error, reason})
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp eval_main, do: "application:ensure_all_started(elixir), 'Elixir.Xeito.Scripts.Vm':main()."

  @doc "Stops the VM and everything it started."
  @spec stop(t()) :: :ok
  def stop(%{pid: pid}) do
    :exec.stop(pid)
    :ok
  end

  defp stop_with(sandbox, result) do
    stop(sandbox)
    result
  end

  @type on_call :: (String.t(), [term()], term() -> {term(), term()})

  @doc """
  Runs `code` in the VM. `limits`: `reductions`, `heap`, `timeout_ms` (also how long the daemon
  waits for the VM between messages). Returns the outcome, the sandbox (`nil` once a VM that
  failed the protocol or fell silent is stopped) and the accumulator `on_call` threaded through
  the script's calls.
  """
  @spec eval(t(), String.t(), map(), term(), on_call()) :: {Vm.outcome(), t() | nil, term()}
  def eval(sandbox, code, limits, acc, on_call) do
    timeout = Map.get(limits, "timeout_ms", 600_000)
    id = "s#{System.unique_integer([:positive])}"
    send_message(sandbox, %{t: "run", id: id, code: code, limits: limits})
    converse(sandbox, %{id: id, timeout: timeout, on_call: on_call}, acc)
  end

  defp converse(sandbox, run, acc) do
    case receive_message(sandbox, run.timeout) do
      {:ok, message, sandbox} -> handle(message, sandbox, run, acc)
      {:error, reason} -> {{:error, failure(reason, run.timeout)}, stop_quietly(sandbox, reason), acc}
    end
  end

  defp handle(%{"t" => "call", "name" => name, "args" => args}, sandbox, run, acc) do
    {value, acc} = run.on_call.(name, args, acc)
    send_message(sandbox, %{t: "reply", id: run.id, value: value})
    converse(sandbox, run, acc)
  end

  defp handle(%{"t" => "done", "value" => value, "stdio" => stdio}, sandbox, _run, acc),
    do: {{:ok, value, stdio}, sandbox, acc}

  defp handle(%{"t" => "failed", "type" => type, "message" => message} = failed, sandbox, _run, acc),
    do: {{:error, %{type: String.to_atom(type), message: message, stdio: failed["stdio"] || ""}}, sandbox, acc}

  defp handle(other, sandbox, _run, acc) do
    stop(sandbox)
    {{:error, %{type: :protocol, message: "unexpected message #{inspect(other)}", stdio: ""}}, nil, acc}
  end

  defp failure(:timeout, timeout), do: %{type: :timeout, message: "the script did not finish in #{timeout} ms", stdio: ""}
  defp failure(reason, _timeout), do: %{type: :crashed, message: "the sandbox stopped: #{inspect(reason)}", stdio: ""}

  # A silent VM is stopped; one that exited already is gone.
  defp stop_quietly(sandbox, :timeout) do
    stop(sandbox)
    nil
  end

  defp stop_quietly(_sandbox, _reason), do: nil

  defp send_message(%{os_pid: os_pid}, message), do: :exec.send(os_pid, Protocol.encode(message))

  # One message: lines may arrive split or several at once, so what follows a line is kept.
  defp receive_message(%{buffer: buffer} = sandbox, timeout) do
    case String.split(buffer, "\n", parts: 2) do
      [line, rest] -> decoded(line, %{sandbox | buffer: rest}, timeout)
      [_partial] -> wait_for_data(sandbox, timeout)
    end
  end

  defp decoded(line, sandbox, timeout) do
    case Protocol.decode(line) do
      {:ok, message} -> {:ok, message, sandbox}
      {:error, _} -> receive_message(sandbox, timeout)
    end
  end

  defp wait_for_data(%{os_pid: os_pid, pid: pid} = sandbox, timeout) do
    receive do
      {:stdout, ^os_pid, data} -> receive_message(%{sandbox | buffer: sandbox.buffer <> data}, timeout)
      {:stderr, ^os_pid, _data} -> wait_for_data(sandbox, timeout)
      {:EXIT, ^pid, reason} -> {:error, reason}
      {:DOWN, _, :process, ^pid, reason} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end
end
