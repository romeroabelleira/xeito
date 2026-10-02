defmodule Mix.Tasks.Xeito.Tui do
  @shortdoc "Terminal UI for xeitod (a session in the current directory)"
  @moduledoc """
  Opens the terminal UI (`Xeito.Tui`) on a session of the running daemon.

      mix xeito.tui [--cwd DIR] [--socket PATH] [--session ID] [--no-status-bar]

  Needs a running daemon (`mix xeito.daemon`) and a real terminal. The TUI is a thin client:
  closing it leaves the session and its runs in the daemon, and `--session ID` reattaches.
  For pipes and plain logs, use `mix xeito.chat`.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Application.put_env(:xeito, :tui, config(args))
    {:ok, _} = Application.ensure_all_started(:term_ui)
    TermUI.Runtime.run(root: Xeito.Tui)
  end

  @doc false
  def config(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [cwd: :string, socket: :string, session: :string, status_bar: :boolean])

    socket = opts[:socket] || Xeito.Api.default_socket()
    if !File.exists?(socket), do: Mix.raise("no daemon at #{socket}; start one with `mix xeito.daemon`")

    [
      socket: socket,
      cwd: Path.expand(opts[:cwd] || "."),
      session: opts[:session],
      status_bar: Keyword.get(opts, :status_bar, true)
    ]
  end
end
