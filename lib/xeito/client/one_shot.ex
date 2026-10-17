defmodule Xeito.Client.OneShot do
  @moduledoc """
  The pure part of `mix xeito.run`: its options, its requests to `Xeito.Api`, and what each daemon event prints.

  - `parse/1` turns the arguments into options (`t:opts/0`) or `{:error, message}`.
  - `text/3` is the request: the argument words, then stdin, separated by a blank line.
  - `open_request/1` and `prompt_request/3` are the API requests: a fresh session, the
    directory's last (`--continue`) or a given one (`--session`); a one-shot prompt, with tools
    off unless `--tools` allows them.
  - `event/2` folds one daemon event (string keys) into actions for the task to perform:
    `{:stdout, iodata}`, `{:stderr, iodata}`, `{:request, map}`, `{:write, path, text}` and
    `{:done, exit_code}`, last.

  Only the answer goes to stdout: streamed as the turn's own deltas when `stream?/2`, else whole
  when the turn finishes, always ending in a newline. With `--json`, stdout gets every event as
  a JSON line instead, then a `result` line with the answer, run, status, chat tier, model,
  tokens and cost. Notices, errors and tool calls go to stderr. A review is denied, as no one
  is there to answer it, unless `--yes`. The exit code is 0 for a turn that ended `done`, else 1.
  """

  alias Xeito.Client.Render
  alias Xeito.Client.StatusBar

  @type opts :: %{
          skill: String.t() | nil,
          machine: String.t() | nil,
          stream: boolean() | nil,
          out: Path.t() | nil,
          extract: :all | :last | nil,
          json: boolean(),
          tools: boolean() | [String.t()],
          yes: boolean(),
          continue: boolean(),
          session: String.t() | nil,
          cwd: Path.t() | nil,
          socket: Path.t() | nil,
          words: [String.t()]
        }

  @type action ::
          {:stdout, iodata()}
          | {:stderr, iodata()}
          | {:request, map()}
          | {:write, Path.t(), String.t()}
          | {:done, 0 | 1}

  @type t :: %__MODULE__{
          opts: opts(),
          stream: boolean(),
          root: String.t() | nil,
          streamed: String.t(),
          usage: StatusBar.usage(),
          tier: String.t() | nil,
          model: String.t() | nil
        }

  defstruct [:opts, :root, :tier, :model, stream: false, streamed: "", usage: StatusBar.new()]

  @switches [
    skill: :string,
    machine: :string,
    stream: :boolean,
    out: :string,
    extract: :boolean,
    extract_last: :boolean,
    json: :boolean,
    tools: :string,
    yes: :boolean,
    continue: :boolean,
    session: :string,
    cwd: :string,
    socket: :string
  ]

  @exclusive [skill: :machine, continue: :session, extract: :extract_last]

  @doc "The options in `args`, or why they are wrong."
  @spec parse([String.t()]) :: {:ok, opts()} | {:error, String.t()}
  def parse(args) do
    # `--tools` alone allows all of them; `--tools=LIST` takes a value, so it cannot eat a word.
    args = Enum.map(args, &if(&1 == "--tools", do: "--tools=all", else: &1))

    case OptionParser.parse(args, strict: @switches, aliases: [s: :stream, o: :out]) do
      {parsed, words, []} -> with :ok <- exclusive(parsed), do: options(parsed, words)
      {_parsed, _words, [{option, _} | _]} -> {:error, "unknown option #{option}"}
    end
  end

  defp exclusive(parsed) do
    case Enum.find(@exclusive, fn {a, b} -> parsed[a] && parsed[b] end) do
      nil -> :ok
      {a, b} -> {:error, "#{flag(a)} or #{flag(b)}, not both"}
    end
  end

  defp flag(name), do: "--" <> String.replace(to_string(name), "_", "-")

  defp options(parsed, words) do
    {:ok,
     %{
       skill: parsed[:skill],
       machine: parsed[:machine],
       stream: parsed[:stream],
       out: parsed[:out],
       extract: extract(parsed),
       json: Keyword.get(parsed, :json, false),
       tools: tools(parsed[:tools]),
       yes: Keyword.get(parsed, :yes, false),
       continue: Keyword.get(parsed, :continue, false),
       session: parsed[:session],
       cwd: parsed[:cwd],
       socket: parsed[:socket],
       words: words
     }}
  end

  defp tools(nil), do: false
  defp tools("all"), do: true
  defp tools(list), do: String.split(list, ",", trim: true)

  defp extract(parsed) do
    cond do
      parsed[:extract] -> :all
      parsed[:extract_last] -> :last
      true -> nil
    end
  end

  @doc """
  The request: the words, then `stdin` (`:eof` when nothing came), with a blank line between.
  Empty text is an error, except for a machine, which may need none.
  """
  @spec text([String.t()], String.t() | :eof, map()) :: {:ok, String.t()} | {:error, String.t()}
  def text(words, stdin, opts \\ %{}) do
    text =
      [Enum.join(words, " "), if(is_binary(stdin), do: stdin, else: "")] |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n")

    if String.trim(text) == "" and opts[:machine] == nil,
      do: {:error, "nothing to send: give the text as arguments or on stdin"},
      else: {:ok, text}
  end

  @doc "The API request that opens the session to run in."
  @spec open_request(opts()) :: map()
  def open_request(opts) do
    cwd = Path.expand(opts.cwd || ".")

    cond do
      opts.continue -> %{"cmd" => "open", "cwd" => cwd}
      opts.session -> %{"cmd" => "attach", "session" => opts.session, "cwd" => cwd}
      true -> %{"cmd" => "start", "cwd" => cwd}
    end
  end

  @doc "The API request for the one-shot turn of `text` in `session`."
  @spec prompt_request(String.t(), String.t(), opts()) :: map()
  def prompt_request(session, text, opts) do
    %{"cmd" => "prompt", "session" => session, "text" => text, "tools" => opts.tools}
    |> put_set("skill", opts.skill)
    |> put_set("machine", opts.machine)
  end

  defp put_set(map, _key, nil), do: map
  defp put_set(map, key, value), do: Map.put(map, key, value)

  @doc "Whether to stream: as asked, else when stdout is a terminal; never for extracts or JSON."
  @spec stream?(opts(), boolean()) :: boolean()
  def stream?(%{json: true}, _tty), do: false
  def stream?(%{extract: extract}, _tty) when extract != nil, do: false
  def stream?(%{stream: nil}, tty), do: tty
  def stream?(%{stream: stream}, _tty), do: stream

  @doc "The fenced code blocks of `answer`, each ending in a newline: all of them, or only the last."
  @spec extract(String.t(), :all | :last) :: String.t()
  def extract(answer, which) do
    blocks = for [_, code] <- Regex.scan(~r/^(?:```|~~~)[^\n]*\n(.*?)^(?:```|~~~)\s*$/ms, answer), do: code
    blocks = if which == :last, do: Enum.take(blocks, -1), else: blocks
    Enum.join(blocks)
  end

  @doc "The fold's start, for `opts`, with stdout a terminal or not."
  @spec new(opts(), boolean()) :: t()
  def new(opts, tty), do: %__MODULE__{opts: opts, stream: stream?(opts, tty)}

  @doc "The actions for one daemon event, and the fold after it."
  @spec event(t(), map()) :: {[action()], t()}
  def event(fold, event) do
    fold = count(fold, event)
    {json(fold, event) ++ actions(fold, event), root(fold, event)}
  end

  defp count(fold, %{"event" => "workspace", "attrs" => %{"chat" => %{"tier" => tier}}}), do: %{fold | tier: tier}

  defp count(fold, %{"event" => "effect_completed", "attrs" => %{"kind" => "chat", "result" => r}} = e),
    do: %{fold | usage: StatusBar.count(fold.usage, e), model: r["model"] || fold.model}

  defp count(fold, event), do: %{fold | usage: StatusBar.count(fold.usage, event)}

  defp root(%{root: nil} = fold, %{"event" => "run_selected", "run" => run}), do: %{fold | root: run}

  defp root(fold, %{"event" => "delta", "run" => run, "attrs" => %{"text" => text}}) when run == fold.root,
    do: %{fold | streamed: fold.streamed <> text}

  defp root(fold, _event), do: fold

  defp json(%{opts: %{json: true}}, %{"event" => "disconnected"}), do: []
  defp json(%{opts: %{json: true}}, event), do: [{:stdout, [JSON.encode!(event), "\n"]}]
  defp json(_fold, _event), do: []

  defp actions(fold, %{"event" => type} = event) when type in ~w(delta turn_finished), do: answer(fold, event)

  defp actions(fold, %{"event" => type} = event) when type in ~w(human_needed error disconnected),
    do: control(fold, event)

  defp actions(fold, %{"event" => type} = event) when type in ~w(notice effect_requested effect_completed),
    do: transcript(fold, event)

  defp actions(_fold, _event), do: []

  defp answer(fold, %{"event" => "delta", "run" => run, "attrs" => %{"text" => text}}),
    do: if(fold.stream and run == fold.root, do: [{:stdout, text}], else: [])

  defp answer(fold, %{"attrs" => attrs} = event), do: finished(fold, attrs, event)

  defp control(fold, %{"event" => "human_needed"} = event), do: review(fold, event)
  defp control(%{root: nil}, %{"event" => "error"} = event), do: [{:stderr, Render.line(event)}, {:done, 1}]
  defp control(fold, %{"event" => "error"} = event), do: transcript(fold, event)
  defp control(_fold, %{"event" => "disconnected"}), do: [{:stderr, "daemon disconnected\n"}, {:done, 1}]

  defp transcript(fold, event), do: if(fold.opts.json or chat?(event), do: [], else: stderr(Render.line(event)))

  defp chat?(%{"attrs" => %{"kind" => kind}}), do: kind in ["chat", :chat]
  defp chat?(_event), do: false

  defp stderr(""), do: []
  defp stderr(text), do: [{:stderr, text}]

  defp review(fold, %{"attrs" => attrs} = event) do
    {cmd, verb} = if fold.opts.yes, do: {"approve", "approved"}, else: {"deny", "denied"}
    note = "· #{verb}: #{what(attrs["call"])}" <> if(fold.opts.yes, do: "\n", else: " (--yes approves)\n")
    [{:stderr, note}, {:request, %{"cmd" => cmd, "session" => event["session"]}}]
  end

  defp what(%{"tool" => "bash", "arguments" => %{"command" => cmd}}), do: "run `#{cmd}`"
  defp what(%{"summary" => summary}), do: summary
  defp what(%{"tool" => tool}), do: tool
  defp what(_call), do: "the step"

  defp finished(fold, attrs, event) do
    answer = attrs["answer"] || ""
    output = output(fold.opts, answer)
    code = if to_string(attrs["status"]) == "done", do: 0, else: 1

    printed(fold, output, attrs) ++
      if(code == 0, do: [], else: stderr(Render.line(event))) ++
      if(fold.opts.out, do: [{:write, fold.opts.out, output}], else: []) ++ [{:done, code}]
  end

  defp output(%{extract: nil}, answer), do: newline(answer)
  defp output(%{extract: which}, answer), do: extract(answer, which)

  defp newline(""), do: ""
  defp newline(text), do: if(String.ends_with?(text, "\n"), do: text, else: text <> "\n")

  defp printed(%{opts: %{json: true}} = fold, _output, attrs), do: [{:stdout, [JSON.encode!(result(fold, attrs)), "\n"]}]
  defp printed(%{stream: true, streamed: ""}, output, _attrs), do: stdout(output)
  # What streamed is printed already: only the newline it may lack.
  defp printed(%{stream: true, streamed: streamed}, _output, _attrs),
    do: if(String.ends_with?(streamed, "\n"), do: [], else: stdout("\n"))

  defp printed(_fold, output, _attrs), do: stdout(output)

  defp stdout(""), do: []
  defp stdout(text), do: [{:stdout, text}]

  defp result(fold, attrs) do
    %{
      "event" => "result",
      "run" => fold.root,
      "status" => to_string(attrs["status"]),
      "answer" => attrs["answer"],
      "tier" => fold.tier,
      "model" => fold.model,
      "tokens_in" => fold.usage.tokens_in,
      "tokens_out" => fold.usage.tokens_out,
      "usd" => fold.usage.usd
    }
  end
end
