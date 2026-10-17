defmodule Mix.Tasks.Xeito.Run do
  @shortdoc "One-shot: a skill or machine on stdin or arguments, the answer on stdout"
  @moduledoc """
  Runs one turn and prints its answer, as a Unix filter: the text from the arguments and/or
  stdin, the answer on stdout, everything else (notices, tool calls, errors) on stderr.

      echo "text" | mix xeito.run --skill summarize
      mix xeito.run --machine run_tests
      git diff | mix xeito.run "review this diff" -o review.md

  Options:

      --skill NAME, --machine NAME   run that skill or machine; neither is a plain chat turn
      -s, --stream / --no-stream     write tokens as they arrive (default: when stdout is a terminal)
      -o, --out FILE                 also write the answer to FILE
      --extract, --extract-last      print only the answer's fenced code blocks, or only the last
      --json                         print the events as JSON Lines, then a result line with the
                                     answer, run, status, tier, model, tokens and cost
      --tools[=LIST]                 allow the model's tools, all or those listed (read,bash,...);
                                     off by default. A review is denied unless --yes
      --yes                          approve what a review asks
      --continue, --session ID       go on in the directory's last session, or in that one
      --cwd DIR                      the workspace (default: the current directory)
      --socket PATH                  the daemon's socket

  Needs a running daemon (`mix xeito.daemon`). The turn is a run in the workspace log like any
  other. A fresh session is closed once the answer is in. The exit status is 0 when the turn
  ended `done`, 1 otherwise.
  """

  use Mix.Task

  alias Xeito.Client
  alias Xeito.Client.OneShot

  @impl true
  def run(args) do
    if Mix.Tasks.Xeito.help?(args), do: Mix.Tasks.Xeito.help(__MODULE__), else: run_task(args)
  end

  defp run_task(args) do
    opts = ok!(OneShot.parse(args))
    text = ok!(OneShot.text(opts.words, stdin(), opts))
    socket = opts.socket || Xeito.Api.default_socket()

    client =
      case Client.connect(socket) do
        {:ok, client} -> client
        {:error, _} -> Mix.raise("no daemon at #{socket}; start one with `mix xeito.daemon`")
      end

    session = reply!(Client.request(client, OneShot.open_request(opts)))["session"]
    reply!(Client.request(client, OneShot.prompt_request(session, text, opts)))
    code = loop(client, OneShot.new(opts, tty?(:stdout)))
    if !opts.continue and !opts.session, do: Client.request(client, %{"cmd" => "close", "session" => session})
    if code != 0, do: exit({:shutdown, code})
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, message}), do: Mix.raise(message)

  defp reply!(%{"ok" => true} = reply), do: reply
  defp reply!(%{"error" => error}), do: Mix.raise(error)

  defp stdin, do: if(tty?(:stdin), do: :eof, else: IO.read(:stdio, :eof))

  defp tty?(which), do: Keyword.get(:io.getopts(:standard_io), which, false)

  defp loop(client, fold) do
    receive do
      {:xeito_event, event} ->
        {actions, fold} = OneShot.event(fold, event)
        Enum.each(actions, &perform(client, &1))

        case List.last(actions) do
          {:done, code} -> code
          _ -> loop(client, fold)
        end
    end
  end

  defp perform(_client, {:stdout, text}), do: IO.write(text)
  defp perform(_client, {:stderr, text}), do: IO.write(:stderr, text)
  defp perform(client, {:request, req}), do: Client.request(client, req)
  defp perform(_client, {:write, path, text}), do: File.write!(path, text)
  defp perform(_client, {:done, _code}), do: :ok
end
