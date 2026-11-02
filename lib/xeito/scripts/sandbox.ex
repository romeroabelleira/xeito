defmodule Xeito.Scripts.Sandbox do
  @moduledoc """
  A script sandbox VM of its own: a small Erlang VM started through erlexec with this release's
  code, running `Xeito.Scripts.Vm.main/0`, that holds no credentials, is not a distributed node
  and reaches the daemon only through `Xeito.Scripts.Protocol` on its stdin and stdout.

    * `start/1` starts the VM and waits for `ready`; `stop/1` ends it with its process group.
    * `eval/4` sends a script with its limits and serves every call the script makes with
      `on_call.(name, args)` until the outcome comes back: the last value and the script's stdio,
      or the failure. A VM that stops or stays silent past `timeout_ms` is killed, and the
      outcome is a `timeout` or `crashed` failure.

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
    args = ["-noshell", "-elixir", "ansi_enabled", "false"] ++ paths ++ ["-eval", eval_main()]

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

  @doc """
  Runs `code` in the VM. `limits`: `reductions`, `heap`, `timeout_ms` (also how long the daemon
  waits for the VM between messages). Returns the outcome and the sandbox, or stops a VM that
  failed the protocol and returns the failure.
  """
  @spec eval(t(), String.t(), map(), (String.t(), [term()] -> term())) :: {Vm.outcome(), t() | nil}
  def eval(sandbox, code, limits, on_call) do
    timeout = Map.get(limits, "timeout_ms", 600_000)
    id = "s#{System.unique_integer([:positive])}"
    send_message(sandbox, %{t: "run", id: id, code: code, limits: limits})
    converse(sandbox, id, timeout, on_call)
  end

  defp converse(sandbox, id, timeout, on_call) do
    case receive_message(sandbox, timeout) do
      {:ok, message, sandbox} -> handle(message, sandbox, id, timeout, on_call)
      {:error, reason} -> {{:error, failure(reason, timeout)}, stop_quietly(sandbox, reason)}
    end
  end

  defp handle(%{"t" => "call", "name" => name, "args" => args}, sandbox, id, timeout, on_call) do
    send_message(sandbox, %{t: "reply", id: id, value: on_call.(name, args)})
    converse(sandbox, id, timeout, on_call)
  end

  defp handle(%{"t" => "done", "value" => value, "stdio" => stdio}, sandbox, _id, _timeout, _on_call),
    do: {{:ok, value, stdio}, sandbox}

  defp handle(%{"t" => "failed", "type" => type, "message" => message} = failed, sandbox, _id, _timeout, _on_call),
    do: {{:error, %{type: String.to_atom(type), message: message, stdio: failed["stdio"] || ""}}, sandbox}

  defp handle(other, sandbox, _id, _timeout, _on_call) do
    stop(sandbox)
    {{:error, %{type: :protocol, message: "unexpected message #{inspect(other)}", stdio: ""}}, nil}
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
