defmodule Xeito.Effects.OsCommand do
  @moduledoc """
  Runs an OS command so that it can be stopped, with everything it started.

  The command runs under erlexec in its own process group. Stopping it sends the group SIGTERM,
  then SIGKILL after `:grace` ms (rounded up to whole seconds, default 2000). It is stopped:

    * on `:timeout` (ms, default 60000), returning the output so far,
    * when the calling process dies (it is linked), and
    * when the VM dies.

  `:on_output` (`fun(binary)`) gets each chunk of output as it arrives. A command that leaves its
  group (`setsid`, double fork) is not stopped.
  """

  @type result :: {:exited, integer(), binary()} | {:timeout, binary()}

  @doc """
  Runs `exe` with `args` in `opts[:cd]`, without a shell, stderr merged into stdout. Raises like
  `System.cmd/3` when `exe` cannot be found. A command killed by a signal exits 128 + signal.
  """
  @spec run(String.t(), [String.t()], keyword()) :: result()
  def run(exe, args, opts) do
    path = System.find_executable(exe) || raise ErlangError, original: :enoent
    grace = Keyword.get(opts, :grace, 2_000)

    options = [
      :stdout,
      {:stderr, :stdout},
      {:group, 0},
      :kill_group,
      {:kill_timeout, max(div(grace + 999, 1_000), 1)},
      {:cd, to_charlist(Keyword.fetch!(opts, :cd))}
    ]

    # The link carries the command's exit back, so exits are trapped while it runs.
    trapping = Process.flag(:trap_exit, true)
    {:ok, pid, os_pid} = :exec.run_link(Enum.map([path | args], &to_charlist/1), options)
    on_output = Keyword.get(opts, :on_output, fn _chunk -> :ok end)
    collected = collect({os_pid, pid, on_output}, now() + Keyword.get(opts, :timeout, 60_000), [])
    result = finish(pid, collected, on_output, grace)
    unlink(pid)
    Process.flag(:trap_exit, trapping)
    result
  end

  defp collect({os_pid, pid, on_output} = command, deadline, acc) do
    receive do
      {:stdout, ^os_pid, data} ->
        on_output.(data)
        collect(command, deadline, [acc | data])

      {:EXIT, ^pid, reason} ->
        {:exited, status(reason), IO.iodata_to_binary(acc)}
    after
      max(deadline - now(), 0) -> {:timeout, os_pid, IO.iodata_to_binary(acc)}
    end
  end

  # A timeout: what the group prints while it stops is part of the output.
  defp finish(pid, {:timeout, os_pid, output}, on_output, grace) do
    :exec.stop(pid)
    {_how, _status, rest} = collect({os_pid, pid, on_output}, now() + grace + 2_000, [])
    {:timeout, output <> rest}
  end

  defp finish(_pid, exited, _on_output, _grace), do: exited

  # A command that did not end even after SIGKILL must not reach this process later.
  defp unlink(pid) do
    Process.unlink(pid)

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp status(:normal), do: 0

  defp status({:exit_status, raw}) do
    case :exec.status(raw) do
      {:status, code} -> code
      {:signal, _name, _core} -> 128 + Bitwise.band(raw, 0x7F)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
