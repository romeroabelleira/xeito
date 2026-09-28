defmodule Xeito.Api do
  @moduledoc """
  The client API of `xeitod`: JSON Lines over a Unix domain socket, one request, reply or event
  per line, modelled on pi's RPC mode (`docs/architecture/07-harness-frontend.md#processes-and-clients`).
  The TUI, the line-mode CLI and the pi bridge are all clients of it.

  Requests carry an `id` that the reply echoes:

      {"id": 1, "cmd": "start", "cwd": "/path/to/project"}  → {"id": 1, "ok": true, "session": "ses-…"}
      {"id": 2, "cmd": "prompt", "session": "ses-…", "text": "the checkout test is red"}
      {"id": 3, "cmd": "approve", "session": "ses-…"}       (also "deny")
      {"id": 4, "cmd": "attach", "session": "ses-…", "cwd": "/path"}
                                    (follow a session; if the daemon restarted, rebuild it from
                                     the workspace log)
      {"id": 5, "cmd": "status", "session": "ses-…"}        (also "history")
      {"id": 6, "cmd": "sessions"}
      {"id": 7, "cmd": "workspace", "session": "ses-…"}      (git and off-box budget; also an event)
      {"id": 7, "cmd": "machines", "cwd": "/path"}           (machines, routing, usage in that log)
      {"id": 8, "cmd": "monitor", "on": true}               (status snapshots every 2 s; "on": false stops)

  Events of attached sessions arrive unsolicited:

      {"event": "delta", "session": "ses-…", "run": "ses-…/t1", "attrs": {"text": "…"}}

  **Security.** The socket runs commands in the user's workspaces, so it lives in a directory
  only the owner can enter (mode 0700) and the socket itself is mode 0600. It is never bound to
  a network address.
  """

  use GenServer

  require Logger

  @doc "The default socket path: `$XEITO_SOCKET`, else `~/.xeito/run/xeito.sock`."
  @spec default_socket() :: Path.t()
  def default_socket,
    do: System.get_env("XEITO_SOCKET") || Path.expand("~/.xeito/run/xeito.sock")

  @doc "Starts the API server. Options: `:socket` (path), `:session` (defaults for new sessions)."
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :socket, &default_socket/0)
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    # The directory must be private: refuse to serve from one we cannot lock down.
    case File.chmod(dir, 0o700) do
      :ok -> :ok
      {:error, reason} -> raise "socket directory #{dir} must be owned by the user (#{reason})"
    end

    File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: :raw])

    File.chmod!(path, 0o600)
    defaults = Keyword.get(opts, :session, [])
    server = self()
    acceptor = spawn_link(fn -> accept(listen, server, defaults) end)

    {:ok, %{listen: listen, path: path, acceptor: acceptor}}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    File.rm(state.path)
  end

  defp accept(listen, server, defaults) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {:ok, pid} =
          DynamicSupervisor.start_child(
            Xeito.ApiConnections,
            {Xeito.Api.Connection, socket: socket, session: defaults}
          )

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :go)
        accept(listen, server, defaults)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("xeito api accept failed: #{inspect(reason)}")
        accept(listen, server, defaults)
    end
  end
end
