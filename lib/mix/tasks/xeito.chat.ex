defmodule Mix.Tasks.Xeito.Chat do
  @shortdoc "Line-mode client for xeitod (a session in the current directory)"
  @moduledoc """
  A minimal, line-mode client of the daemon: type a request, watch the machine work, approve or
  deny commands sent to review. It is the TUI without the layout, and useful where the TUI is
  not (logs, pipes, a plain SSH session).

      mix xeito.chat [--cwd DIR] [--socket PATH] [--session ID]

  Needs a running daemon (`mix xeito.daemon`). Slash commands are passed through (`/help`).
  A line ending in `\\` goes on in the next, for a prompt of several lines.
  `y` / `n` answer a pending review. `/quit` (or Ctrl-D) quits; the session keeps running in the
  daemon, and `--session ID` attaches to it again.
  """

  use Mix.Task

  alias Xeito.Client
  alias Xeito.Client.Render

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [cwd: :string, socket: :string, session: :string])

    socket = opts[:socket] || Xeito.Api.default_socket()

    client =
      case Client.connect(socket) do
        {:ok, client} -> client
        {:error, _} -> Mix.raise("no daemon at #{socket}; start one with `mix xeito.daemon`")
      end

    session = open(client, opts)

    IO.puts(
      IO.ANSI.faint() <>
        "session #{session} · /help · y/n answer a review · /quit" <> IO.ANSI.reset()
    )

    printer = self()
    spawn_link(fn -> input_loop(client, session, printer) end)
    event_loop()
  end

  defp open(client, opts) do
    case Client.request(client, open_request(opts)) do
      %{"ok" => true, "session" => id} -> id
      %{"error" => error} -> Mix.raise("could not open a session: #{error}")
    end
  end

  @doc false
  def open_request(opts) do
    cwd = Path.expand(opts[:cwd] || ".")

    case opts[:session] do
      nil -> %{"cmd" => "start", "cwd" => cwd}
      id -> %{"cmd" => "attach", "session" => id, "cwd" => cwd}
    end
  end

  defp input_loop(client, session, printer, acc \\ "") do
    case IO.gets("") do
      :eof ->
        send(printer, :quit)

      {:error, _} ->
        send(printer, :quit)

      line ->
        case take_line(acc, line) do
          {:more, acc} -> input_loop(client, session, printer, acc)
          {:done, text} -> run_line(client, session, printer, String.trim(text))
        end
    end
  end

  defp run_line(_client, _session, printer, quit) when quit in ["/quit", "/exit"], do: send(printer, :quit)
  defp run_line(client, session, printer, text), do: send_line(client, session, printer, text)

  @doc false
  # A line read, added to the prompt so far: one ending in `\` goes on in the next line.
  def take_line(acc, line) do
    line = line |> String.trim_trailing("\n") |> String.trim_trailing("\r")

    if String.ends_with?(line, "\\"),
      do: {:more, acc <> String.slice(line, 0..-2//1) <> "\n"},
      else: {:done, acc <> line}
  end

  defp send_line(client, session, printer, line) do
    with %{} = req <- request_for(line, session),
         %{"ok" => false, "error" => error} <- Client.request(client, req),
         do: IO.puts(IO.ANSI.red() <> error <> IO.ANSI.reset())

    input_loop(client, session, printer)
  end

  @doc false
  def request_for("", _session), do: nil
  def request_for("y", session), do: %{"cmd" => "approve", "session" => session}
  def request_for("n", session), do: %{"cmd" => "deny", "session" => session}
  def request_for(text, session), do: %{"cmd" => "prompt", "session" => session, "text" => text}

  defp event_loop do
    receive do
      :quit ->
        :ok

      {:xeito_event, %{"event" => "disconnected"}} ->
        IO.puts("daemon disconnected")

      {:xeito_event, event} ->
        IO.write(Render.line(event))
        event_loop()
    end
  end
end
