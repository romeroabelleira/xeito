defmodule Xeito.Effects.OsCommand do
  @moduledoc """
  Runs an OS command so that it can be stopped, with everything it started.

  Closing a port does not signal the OS process behind it: a `sh -c` left by a timed-out
  `System.cmd`, or by a halted run's killed effect task, kept running with its children. Here
  erlexec (`:exec`) runs the command in its own process group and, when it is stopped, sends the
  group SIGTERM, then SIGKILL after a grace period (`:grace`, in whole seconds, default 2 s).
  That happens:

    * on a timeout (`:timeout`, default 60 s), which returns the output so far,
    * when the process waiting for the command dies (a halt kills effect tasks with `:kill`):
      the command is linked to it, and
    * when the daemon's VM dies: erlexec's port program stops what it started.

  A command that leaves its group (`setsid`, a daemonising double fork) is not stopped.
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

    # The link stops the command if this process dies, and is how its exit comes back: exits
    # are trapped while it runs.
    trapping = Process.flag(:trap_exit, true)
    {:ok, pid, os_pid} = :exec.run_link(Enum.map([path | args], &to_charlist/1), options)
    result = finish(pid, collect(os_pid, pid, now() + Keyword.get(opts, :timeout, 60_000), []), grace)
    unlink(pid)
    Process.flag(:trap_exit, trapping)
    result
  end

  defp collect(os_pid, pid, deadline, acc) do
    receive do
      {:stdout, ^os_pid, data} -> collect(os_pid, pid, deadline, [acc | data])
      {:EXIT, ^pid, reason} -> {:exited, status(reason), IO.iodata_to_binary(acc)}
    after
      max(deadline - now(), 0) -> {:timeout, os_pid, IO.iodata_to_binary(acc)}
    end
  end

  # A timeout: what the group prints while it stops is part of the output.
  defp finish(pid, {:timeout, os_pid, output}, grace) do
    :exec.stop(pid)
    {_how, _status, rest} = collect(os_pid, pid, now() + grace + 2_000, [])
    {:timeout, output <> rest}
  end

  defp finish(_pid, exited, _grace), do: exited

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
