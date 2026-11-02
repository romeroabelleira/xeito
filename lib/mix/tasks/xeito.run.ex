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
      --as TYPE|FILE                 constrain the answer to a decision type (triage, risk, ...)
                                     or a JSON Schema file, and print it as JSON
      --tools[=LIST]                 allow the model's tools, all or those listed (read,bash,...);
                                     off by default. A review is denied unless --yes
      --yes                          approve what a review asks
      --tier NAME, --model TAG       the chat tier (local, remote, remote_frontier) or model for
                                     this call; spend limits still apply
      -t, --temperature N            sampling temperature
      --think / --no-think           the model's thinking on or off
      -v, --var NAME=VALUE           fill {{NAME}} in the skill (repeatable); a skill declares its
                                     variables and defaults under metadata: vars:
      -C, --context NAME             add the named context, .agents/contexts/NAME.md in the
                                     workspace or your home, after the text (repeatable)
      --dry-run, --print-prompt      print the request a real call would send, calling no model
      -l, --list                     list the skills seen from the workspace with their layer:
                                     project, user, or the samples shipped with Xeito; a skill
                                     an earlier layer's hides is marked shadowed
      --print-skill NAME             print a skill's SKILL.md
      --print-functions              print one shell function per skill, to source
      --continue, --session ID       go on in the directory's last session, or in that one
      --cwd DIR                      the workspace (default: the current directory)
      --socket PATH                  the daemon's socket

  A skill may choose its chat tier and output under `metadata:` (`tier: remote_frontier`,
  `output: json:triage`); the call's own flags win, and a remote tier is honoured only where the
  policy lets input leave the machine (the notice says so otherwise).

  Needs a running daemon (`mix xeito.daemon`), except for `--list`, `--print-skill` and
  `--print-functions`. The turn
  is a run in the workspace log like any other. A fresh session is closed once the answer is in.
  The exit status is 0 when the turn ended `done`, 1 otherwise, or when `--as` got no JSON.
  """

  use Mix.Task

  alias Xeito.Client
  alias Xeito.Client.OneShot
  alias Xeito.Skills

  @impl true
  def run(args) do
    if Mix.Tasks.Xeito.help?(args), do: Mix.Tasks.Xeito.help(__MODULE__), else: run_task(args)
  end

  defp run_task(args) do
    opts = ok!(OneShot.parse(args))
    cwd = Path.expand(opts.cwd || ".")

    cond do
      opts.list -> IO.write(OneShot.skill_list(Skills.all(cwd), cwd))
      opts.print_skill -> IO.write(skill_file(opts.print_skill, cwd))
      opts.print_functions -> IO.write(OneShot.functions(Skills.discover(cwd)))
      true -> call(%{opts | as: as(opts.as)})
    end
  end

  defp skill_file(name, cwd) do
    case Enum.find(Skills.discover(cwd), &(&1.name == name)) do
      nil -> Mix.raise("no skill named #{inspect(name)}")
      skill -> File.read!(Path.join(skill.dir, "SKILL.md"))
    end
  end

  # A file is a JSON Schema; anything else names a decision type.
  defp as(path) when is_binary(path), do: if(File.regular?(path), do: ok!(OneShot.schema(File.read!(path))), else: path)
  defp as(nil), do: nil

  defp call(opts) do
    text = ok!(OneShot.text(opts.words, stdin(), opts))
    client = connect!(opts.socket || Xeito.Api.default_socket())
    session = reply!(Client.request(client, OneShot.open_request(opts)))["session"]
    reply = reply!(Client.request(client, OneShot.prompt_request(session, text, opts)))

    code =
      if opts.dry_run, do: print_request(reply["request"], opts), else: loop(client, OneShot.new(opts, tty?(:stdout)))

    close_fresh(client, session, opts)
    if code != 0, do: exit({:shutdown, code})
  end

  defp connect!(socket) do
    case Client.connect(socket) do
      {:ok, client} -> client
      {:error, _} -> Mix.raise("no daemon at #{socket}; start one with `mix xeito.daemon`")
    end
  end

  # Only a session this call started.
  defp close_fresh(_client, _session, %{continue: true}), do: :ok
  defp close_fresh(_client, _session, %{session: id}) when id != nil, do: :ok
  defp close_fresh(client, session, _opts), do: Client.request(client, %{"cmd" => "close", "session" => session})

  defp print_request(request, opts) do
    IO.write(OneShot.dry_run(request, opts))
    0
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
