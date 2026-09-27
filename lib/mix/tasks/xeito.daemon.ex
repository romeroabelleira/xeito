defmodule Mix.Tasks.Xeito.Daemon do
  @shortdoc "Runs xeitod: runs, logs and the client API socket"
  @moduledoc """
  Runs the Xeito daemon in the foreground with the client API (`Xeito.Api`) enabled.

      mix xeito.daemon [--socket PATH]

  The socket defaults to `$XEITO_SOCKET` or `~/.xeito/run/xeito.sock`. Tier endpoints come from
  the environment (`config/runtime.exs`). Each session logs to its workspace's
  `.xeito/log.sqlite`. For a long-running daemon, run this under `systemd --user` (see
  `deploy/`), or build a release in P8.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [socket: :string])
    if socket = opts[:socket], do: System.put_env("XEITO_SOCKET", socket)

    Application.put_env(:xeito, :api, true)
    Mix.Task.run("app.start")
    Mix.shell().info("xeitod listening on #{Xeito.Api.default_socket()}")
    Process.sleep(:infinity)
  end
end
