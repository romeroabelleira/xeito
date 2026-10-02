defmodule Xeito.Tui do
  @moduledoc """
  The terminal UI: a client of `xeitod` in the Elm architecture of TermUI
  (`docs/architecture/07-harness-frontend.md`, `docs/architecture/08-tech-stack.md#the-tui-the-weakest-link`).

      ┌ xeito · ~/src/shop · FixFailingTest ─────────────────────────────┐
      │ transcript (Xeito.Client.Render): intent, decisions, tool calls,  │
      │ streamed model output                                             │
      │ ───────────────────────────────────────────────────────────────── │
      │ > prompt                                                          │
      │ ───────────────────────────────────────────────────────────────── │
      │ state verifying · 14.2 s · 3 decisions · review: y/n              │
      └───────────────────────────────────────────────────────────────────┘

  A toggleable **status bar** (Ctrl-T, or `/statusbar`; segments with `/statusbar show|hide`,
  saved in `Xeito.Client.Config`) adds one line, above the status line: GPU, model services and
  CPU from the daemon's `Xeito.Monitor`, and the session's usage, determinism budget, spend and
  queues (`Xeito.Client.StatusBar`). While it is hidden, the daemon does not poll for it.

  `/quit` (or `/exit`, Ctrl-D, Ctrl-C) closes the TUI; the session keeps running in the daemon.

  The prompt's cursor blinks like an editor's: solid while you type, blinking in between, and
  solid again (with no timer running) after 10 s without a key.

  Keys: Enter sends (and steps a paused run when the prompt is empty); a pending review is
  answered with `y` or `n` and Enter, or with text saying what to do instead; Esc halts the
  running turn; Up / Down recall earlier prompts (the line being typed comes back past the
  newest); Tab completes a `/command`, a machine after `/machine ` or a skill after `/skill:`,
  and each further Tab shows the next match; PgUp / PgDn scroll; Ctrl-C or Ctrl-D quit (the
  session keeps running in the daemon and can be reattached with `--session`).

  The TUI owns no run state: everything shown comes from daemon events, so it can crash, be
  closed or be replaced without touching the runs.
  """

  use TermUI.Elm

  alias TermUI.Event
  alias TermUI.Renderer.Style
  alias TermUI.Widgets.TextInput
  alias Xeito.Client
  alias Xeito.Client.Config
  alias Xeito.Client.Render
  alias Xeito.Client.StatusBar

  @max_lines 5_000
  # Blink half-period and how long the cursor keeps blinking after the last key (as GTK does), so
  # an idle TUI stops waking up.
  @blink_ms 530
  @blink_for_ms 10_000
  @placeholder "ask, or /help"

  # The TUI's own commands (run_line/2); Tab completes them along with the daemon's.
  @own_commands ~w(quit exit statusbar)

  # --- init ----------------------------------------------------------------------------------

  @impl true
  def init(_runtime_opts) do
    opts = Application.get_env(:xeito, :tui, [])
    {:ok, client} = Client.connect(Keyword.fetch!(opts, :socket))
    {session, status} = open(client, opts)

    [
      client: client,
      session: session,
      cwd: status["cwd"] || opts[:cwd],
      size: TermUI.Platform.terminal_size(),
      earlier: if(opts[:session], do: earlier_turns(client, session), else: []),
      prefs: Config.load(),
      prefs_file: Config.path()
    ]
    |> Keyword.merge(Keyword.take(opts, [:status_bar]))
    |> new()
    |> wake_cursor()
    |> tap(&if(&1.bar, do: Client.request(client, %{"cmd" => "monitor", "on" => true})))
    |> tap(&Client.request(client, %{"cmd" => "workspace", "session" => &1.session}))
  end

  @doc """
  An idle TUI state for a session: `client`, `session`, `cwd`, `size` (`{rows, cols}`), the
  `earlier` transcript lines, the preferences and the file they are saved in (`prefs`,
  `prefs_file`), and optionally `status_bar` to override the preferences' visibility.
  """
  @spec new(keyword()) :: map()
  def new(opts) do
    {rows, cols} = Keyword.fetch!(opts, :size)
    prefs = Keyword.fetch!(opts, :prefs)
    {:ok, input} = TextInput.init(TextInput.new(placeholder: @placeholder, width: cols - 2))
    session = Keyword.fetch!(opts, :session)

    %{
      client: Keyword.fetch!(opts, :client),
      session: session,
      cwd: opts[:cwd],
      lines: Keyword.get(opts, :earlier, []) ++ ["session #{session} · /help · Esc halts · /quit"],
      partial: "",
      input: TextInput.set_focused(input, true),
      width: cols,
      height: rows,
      scroll: 0,
      machine: nil,
      leaf: "idle",
      started: nil,
      decisions: 0,
      tier: nil,
      usd: 0.0,
      waiting: false,
      paused: false,
      bar: Keyword.get(opts, :status_bar, prefs["status_bar"]["visible"]),
      hidden: prefs["status_bar"]["hidden"],
      prefs: prefs,
      prefs_file: Keyword.fetch!(opts, :prefs_file),
      monitor: nil,
      workspace: nil,
      workspace_at: nil,
      usage: StatusBar.new(),
      cursor_on: true,
      # A Risk decision waiting for the line it marks: `{colour, confidence in superscript}`.
      marker: nil,
      blink: 0,
      blink_until: 0,
      # Earlier prompts for Up/Down, newest first; the one shown (-1: the line being typed,
      # kept as the draft meanwhile).
      prompt_history: [],
      history_index: -1,
      history_draft: "",
      # While Tab cycles through completions: `{candidates, shown}`, the index of the one shown.
      completion: nil
    }
  end

  defp open(client, opts) do
    req =
      case opts[:session] do
        nil -> %{"cmd" => "start", "cwd" => opts[:cwd]}
        id -> %{"cmd" => "attach", "session" => id, "cwd" => opts[:cwd]}
      end

    case Client.request(client, req) do
      %{"ok" => true, "session" => id} = reply -> {id, reply["status"] || %{"cwd" => opts[:cwd]}}
      %{"error" => error} -> raise "could not open a session: #{error}"
    end
  end

  # On reattach, the conversation so far (the runs' details stay in the log).
  defp earlier_turns(client, session) do
    case Client.request(client, %{"cmd" => "history", "session" => session}) do
      %{"ok" => true, "history" => history} ->
        for %{"role" => role, "content" => content} <- history,
            role in ["user", "assistant"] and content not in [nil, ""],
            do: history_line(role, content)

      _ ->
        []
    end
  end

  defp history_line("user", content), do: "> " <> first_line(content)
  defp history_line(_role, content), do: first_line(content)

  defp first_line(text), do: text |> String.split("\n") |> hd()

  # --- events → messages ---------------------------------------------------------------------

  @impl true
  def event_to_msg(%Event.Key{} = key, state), do: key_to_msg(key, state)
  def event_to_msg(%Event.Resize{width: w, height: h}, _state), do: {:msg, {:resize, w, h}}
  def event_to_msg(_event, _state), do: :ignore

  @keys %{
    enter: :submit,
    escape: :halt,
    ESC: :halt,
    up: {:recall, :older},
    down: {:recall, :newer},
    page_up: {:scroll, 10},
    page_down: {:scroll, -10}
  }

  defp key_to_msg(%Event.Key{key: key, modifiers: mods}, _state) when key in [:c, "c", :d, "d", :t, "t"] and mods != [],
    do: control_key(key, mods)

  defp key_to_msg(%Event.Key{key: :tab}, _state), do: {:msg, :complete}

  defp key_to_msg(%Event.Key{key: key} = event, _state) do
    case Map.get(@keys, key) do
      nil -> {:msg, {:input, event}}
      msg -> {:msg, msg}
    end
  end

  # Ctrl-T toggles the status bar; Ctrl-C and Ctrl-D quit. Other modifiers do nothing.
  defp control_key(key, mods) do
    cond do
      :ctrl not in mods -> :ignore
      key in [:t, "t"] -> {:msg, :toggle_bar}
      true -> {:msg, :quit}
    end
  end

  # Daemon events and request replies arrive as plain process messages.
  # Each monitor tick also refreshes the workspace (git, budget) if it is older than 10 s.
  def handle_info({:xeito_event, %{"event" => "monitor", "attrs" => snapshot}}, state),
    do: {on_monitor(snapshot, state), []}

  def handle_info({:xeito_event, %{"event" => "workspace", "attrs" => ws}}, state),
    do: {%{state | workspace: ws, workspace_at: now()}, []}

  def handle_info({:xeito_event, event}, state), do: {apply_event(state, event), []}

  def handle_info({:xeito_reply, %{"ok" => false, "error" => error}}, state), do: {append(state, "✗ #{error}\n"), []}

  # Only the timer of the latest key counts; older ones are stale.
  def handle_info({:blink, gen}, %{blink: gen} = state), do: {blink(gen, state), []}
  def handle_info(_msg, state), do: {state, []}

  defp on_monitor(snapshot, state) do
    if state.workspace_at == nil or now() - state.workspace_at > 10_000,
      do: request(state, %{"cmd" => "workspace", "session" => state.session})

    %{state | monitor: snapshot, workspace_at: state.workspace_at || now()}
  end

  # The cursor blinks until `blink_until`, then stays solid with no timer running.
  defp blink(gen, state) do
    if now() < state.blink_until do
      Process.send_after(self(), {:blink, gen}, @blink_ms)
      %{state | cursor_on: not state.cursor_on}
    else
      %{state | cursor_on: true}
    end
  end

  # --- update --------------------------------------------------------------------------------

  # Every message here comes from a key, except a resize: a key shows the cursor solid and
  # restarts the blinking phase.
  @impl true
  def update({:resize, _, _} = msg, state), do: handle_update(msg, state)
  def update(msg, state), do: handle_update(msg, state |> wake_cursor() |> keep_completion(msg))

  @doc false
  def wake_cursor(state) do
    gen = state.blink + 1
    Process.send_after(self(), {:blink, gen}, @blink_ms)
    %{state | cursor_on: true, blink: gen, blink_until: now() + @blink_for_ms}
  end

  defp handle_update(:quit, state), do: {state, [TermUI.Command.quit(:normal)]}
  defp handle_update(:submit, state), do: state.input |> TextInput.get_value() |> String.trim() |> submit(state)
  defp handle_update({:review, answer}, state), do: review(answer, state)
  defp handle_update({:recall, direction}, state), do: state |> recall(direction) |> recalled(state)

  defp handle_update(msg, state) when msg in [:halt, :complete], do: line_key(msg, state)

  defp handle_update(msg, state), do: screen_update(msg, state)

  defp line_key(:halt, state), do: halt(state)
  defp line_key(:complete, state), do: complete(state)

  # Only Tab continues a completion; any other key ends it.
  defp keep_completion(state, :complete), do: state
  defp keep_completion(state, _msg), do: %{state | completion: nil}

  # An empty line steps a paused run, and otherwise does nothing.
  defp submit("", %{paused: true} = state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/next"})
    {%{state | paused: false}, []}
  end

  defp submit("", state), do: {state, []}
  defp submit(text, state), do: run_line(text, remember(state, text))

  defp review(answer, state) do
    {cmd, said} = if answer == "y", do: {"approve", "approved"}, else: {"deny", "denied"}
    request(state, %{"cmd" => cmd, "session" => state.session})
    {append(%{state | waiting: false}, "  #{said}\n"), []}
  end

  defp recalled({:ok, text, state}, _state), do: {%{state | input: put_text(state.input, text)}, []}
  defp recalled(:none, state), do: {state, []}

  # Halts the running turn (the daemon's `/halt`); with nothing running, Esc does nothing.
  defp halt(%{leaf: leaf} = state) when leaf in ["idle", "disconnected"], do: {state, []}

  defp halt(state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/halt"})
    {state, []}
  end

  defp screen_update(:toggle_bar, state), do: {set_bar(state, not state.bar), []}

  defp screen_update({:statusbar, args}, state) do
    state = %{state | input: TextInput.clear(state.input)}
    {statusbar(String.split(args, ~r/[\s,]+/, trim: true), state), []}
  end

  defp screen_update({:input, event}, state) do
    {:ok, input} = TextInput.handle_event(event, state.input)
    {%{state | input: input}, []}
  end

  defp screen_update({:scroll, n}, state), do: {%{state | scroll: max(state.scroll + n, 0)}, []}

  defp screen_update({:resize, w, h}, state),
    do: {%{state | width: w, height: h, input: Map.put(state.input, :width, w - 2)}, []}

  defp screen_update(_msg, state), do: {state, []}

  # --- status bar preferences ----------------------------------------------------------------

  defp set_bar(state, bar) do
    request(state, %{"cmd" => "monitor", "on" => bar})
    %{state | bar: bar, monitor: if(bar, do: state.monitor)}
  end

  defp statusbar(args, state) when args in [[], ["on"], ["off"]],
    do: state |> set_bar(visible?(args, state)) |> save_prefs()

  defp statusbar(["reset"], state), do: save_prefs(%{set_bar(state, true) | hidden: []})

  defp statusbar([verb | names], state) when verb in ["show", "hide"] and names != [],
    do: set_segments(verb, names, state)

  defp statusbar(["segments"], state), do: list_segments(state)

  defp statusbar(_args, state),
    do: append(state, "/statusbar [on|off|reset|segments] · /statusbar show|hide <segment>[,<segment>]\n")

  # A bare /statusbar toggles.
  defp visible?([], state), do: not state.bar
  defp visible?(["on"], _state), do: true
  defp visible?(["off"], _state), do: false

  defp set_segments(verb, names, state) do
    case names -- StatusBar.segments() do
      [] -> save_prefs(%{state | hidden: hidden(verb, names, state.hidden)})
      unknown -> append(state, "✗ unknown segment #{Enum.join(unknown, ", ")}; see /statusbar segments\n")
    end
  end

  defp hidden("hide", names, hidden), do: Enum.uniq(hidden ++ names)
  defp hidden("show", names, hidden), do: hidden -- names

  defp list_segments(state) do
    listed = Enum.map_join(StatusBar.segments(), " ", &if(&1 in state.hidden, do: "·#{&1}", else: &1))
    append(state, "status bar #{if state.bar, do: "on", else: "off"} · segments: #{listed} (· hidden)\n")
  end

  # Preferences are saved on every change; a failed write keeps them for this session only.
  defp save_prefs(state) do
    prefs =
      put_in(state.prefs, ["status_bar"], %{"visible" => state.bar, "hidden" => state.hidden})

    case Config.save(prefs, state.prefs_file) do
      :ok ->
        %{state | prefs: prefs}

      {:error, reason} ->
        append(%{state | prefs: prefs}, "✗ could not save preferences: #{inspect(reason)}\n")
    end
  end

  # Requests are sent from a task, so the UI never waits on the daemon.
  defp request(state, req) do
    me = self()
    Task.start(fn -> send(me, {:xeito_reply, Client.request(state.client, req)}) end)
  end

  # --- the prompt line -----------------------------------------------------------------------

  # Handled here: these change how this client shows things, never what runs.
  defp run_line(quit, state) when quit in ["/quit", "/exit"], do: handle_update(:quit, state)
  defp run_line("/statusbar" <> args, state), do: handle_update({:statusbar, args}, state)

  # A pending review: y or n answers it, other text says what to do instead (the daemon takes a
  # prompt during a review as that answer).
  defp run_line(answer, %{waiting: true} = state) when answer in ["y", "n"],
    do: handle_update({:review, answer}, %{state | input: TextInput.clear(state.input)})

  defp run_line("/" <> _ = command, state), do: send_line(command, state)

  defp run_line(text, %{waiting: true} = state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => text})
    {append(%{state | input: TextInput.clear(state.input), waiting: false}, "  instead: #{text}\n"), []}
  end

  defp run_line(text, state), do: send_line(text, state)

  defp send_line(text, state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => text})
    {append(%{state | input: TextInput.clear(state.input), scroll: 0}, "> #{text}\n"), []}
  end

  # Every line sent is remembered, as a shell does, but not twice in a row.
  defp remember(%{prompt_history: [text | _]} = state, text), do: %{state | history_index: -1, history_draft: ""}

  defp remember(state, text),
    do: %{state | prompt_history: [text | state.prompt_history], history_index: -1, history_draft: ""}

  # Up from the line being typed keeps it as the draft, and Down past the newest prompt brings it
  # back. With nowhere to go, nothing changes, not even the cursor.
  defp recall(%{history_index: -1, prompt_history: [newest | _]} = state, :older),
    do: {:ok, newest, %{state | history_index: 0, history_draft: TextInput.get_value(state.input)}}

  defp recall(%{history_index: i, prompt_history: history} = state, :older) when i >= 0 and i + 1 < length(history),
    do: {:ok, Enum.at(history, i + 1), %{state | history_index: i + 1}}

  defp recall(%{history_index: i} = state, :newer) when i >= 0 do
    text = if i == 0, do: state.history_draft, else: Enum.at(state.prompt_history, i - 1)
    {:ok, text, %{state | history_index: i - 1}}
  end

  defp recall(_state, _direction), do: :none

  # TextInput.set_value/2 puts the cursor at the start; a recalled line is edited at its end.
  defp put_text(input, text), do: %{TextInput.set_value(input, text) | cursor_col: String.length(text)}

  # Tab shows the first completion of the line; each further Tab the next, around and around.
  defp complete(%{completion: {candidates, shown}} = state),
    do: show(state, candidates, rem(shown + 1, length(candidates)))

  defp complete(state) do
    case state.input |> TextInput.get_value() |> completions(state.cwd) do
      [] -> {state, []}
      candidates -> show(state, candidates, 0)
    end
  end

  defp show(state, candidates, i),
    do: {%{state | input: put_text(state.input, Enum.at(candidates, i)), completion: {candidates, i}}, []}

  @doc "The commands Tab completes: the daemon's and the TUI's own."
  @spec commands() :: [String.t()]
  def commands, do: Enum.sort(@own_commands ++ Xeito.Session.commands())

  # The completions of a line, in order: a command, a machine after `/machine `, a skill of the
  # workspace after `/skill:`. Case is ignored.
  defp completions("/machine " <> part, _cwd), do: matching("/machine ", Map.keys(Xeito.Session.Router.machines()), part)
  defp completions("/skill:" <> part, cwd), do: matching("/skill:", Enum.map(Xeito.Skills.discover(cwd), & &1.name), part)
  defp completions("/" <> part, _cwd), do: matching("/", commands(), part)
  defp completions(_line, _cwd), do: []

  defp matching(lead, names, part) do
    part = String.downcase(part)
    for name <- Enum.sort(names), String.starts_with?(String.downcase(name), part), do: lead <> name
  end

  # --- daemon events -------------------------------------------------------------------------

  @doc false
  # A Risk decision is not a line of its own: it marks the line it applies to (the command, or
  # the review asking about it) with a coloured dot in the gutter, like a breakpoint.
  def apply_event(state, %{"event" => "decision_made", "attrs" => %{"decision_type" => type} = a} = event)
      when type in ["Xeito.Decisions.Risk", "Elixir.Xeito.Decisions.Risk"] do
    track(%{state | usage: StatusBar.count(state.usage, event), marker: risk_marker(a)}, "decision_made", event)
  end

  def apply_event(state, %{"event" => type} = event) do
    %{state | usage: StatusBar.count(state.usage, event)}
    |> track(type, event)
    |> append(Render.line(event))
  end

  @risk_colors %{"safe" => :green, "review" => :yellow, "abstain" => :yellow, "forbidden" => :red}

  # The dot's colour is the decision; beside it, in superscript (a terminal's small font), its
  # confidence in percent.
  defp risk_marker(a) do
    value = to_string(a["value"])
    conf = if is_number(a["confidence"]), do: round(a["confidence"] * 100)
    {Map.get(@risk_colors, value, :white), superscript(conf)}
  end

  defp superscript(nil), do: ""

  defp superscript(n),
    do:
      n
      |> Integer.to_string()
      |> String.graphemes()
      |> Enum.map_join(&Enum.at(~w(⁰ ¹ ² ³ ⁴ ⁵ ⁶ ⁷ ⁸ ⁹), String.to_integer(&1)))

  @progress ["run_selected", "state_entered", "decision_made", "intent"]

  defp track(state, type, event) when type in @progress, do: progress(state, type, event)
  defp track(state, type, _event), do: turn_status(state, type)

  # Where the run is, and what it has cost so far.
  defp progress(state, "run_selected", %{"attrs" => a}),
    do: %{state | machine: short(a["machine"]), started: now(), decisions: 0, usd: 0.0}

  defp progress(state, "state_entered", %{"run" => run, "attrs" => %{"state" => leaf}}) do
    if internal?(run), do: state, else: %{state | leaf: to_string(leaf)}
  end

  defp progress(state, "decision_made", %{"attrs" => a}),
    do: %{state | decisions: state.decisions + 1, tier: a["actor"], usd: state.usd + usd(a["usd"])}

  defp progress(state, "intent", %{"attrs" => a}),
    do: %{state | decisions: state.decisions + 1, leaf: "intent", tier: a["actor"]}

  defp usd(usd) when is_number(usd), do: usd
  defp usd(_usd), do: 0.0

  defp turn_status(state, "human_needed"), do: %{state | waiting: true}
  defp turn_status(state, "paused"), do: %{state | paused: true}
  defp turn_status(state, "turn_finished"), do: %{state | leaf: "idle", waiting: false, paused: false, started: nil}
  defp turn_status(state, "disconnected"), do: %{state | leaf: "disconnected"}
  defp turn_status(state, _type), do: state

  defp internal?(run), do: String.ends_with?(run, "/esc") or String.ends_with?(run, "/intent")

  # --- view ----------------------------------------------------------------------------------

  # Text arrives in pieces (streamed deltas); complete lines move into the transcript.
  @doc false
  def append(state, ""), do: state

  def append(state, text) do
    [first | rest] = String.split(state.partial <> text, "\n")

    case Enum.split(rest, -1) do
      {[], []} ->
        %{state | partial: first}

      {complete, [partial]} ->
        {complete, state} = mark([first | complete], state)
        lines = Enum.take(state.lines ++ complete, -@max_lines)
        %{state | lines: lines, partial: partial}
    end
  end

  @impl true
  def view(state) do
    bar =
      with true <- state.bar,
           line when line != "" <-
             StatusBar.line(state.usage, state.monitor, state.workspace, state.hidden, state.width - 1) do
        [line]
      else
        _ -> []
      end

    # The header, the prompt line between its two borders, the bar and the status line.
    body_height = max(state.height - 5 - length(bar), 1)

    stack(:vertical, [
      text(
        pad(" xeito · #{state.cwd} · #{state.machine || "ready"}", state.width),
        header_style()
      ),
      stack(:vertical, Enum.map(visible(state, body_height), &line_node/1)),
      border(state.width),
      stack(:horizontal, [
        text("> "),
        input_line(state, state.width - 2)
      ]),
      border(state.width),
      stack(:vertical, Enum.map(bar, &text(pad(" " <> &1, state.width), bar_style()))),
      text(pad(status_line(state), state.width), status_style(state))
    ])
  end

  # The input line is drawn here; TermUI's TextInput keeps the text and handles editing. Its own
  # cursor (reverse video) was easy to miss, and its style cannot be changed, so the typing
  # position is a solid block in a colour nothing else on screen uses. In the blink's off phase
  # the cell is drawn plain. Long input scrolls so the cursor stays visible; an empty line shows
  # the placeholder, dimmed, after the cursor.

  @doc false
  def input_line(state, width) do
    value = TextInput.get_value(state.input)
    col = min(state.input.cursor_col, String.length(value))
    start = max(col - (width - 1), 0)
    shown = String.slice(value, start, width)
    {before, rest} = String.split_at(shown, col - start)
    {at, after_cursor} = if rest == "", do: {" ", ""}, else: String.split_at(rest, 1)

    hint =
      if value == "",
        do: [text(" " <> String.slice(@placeholder, 0, max(width - 2, 0)), placeholder_style())],
        else: []

    stack(
      :horizontal,
      [text(before), text(at, if(state.cursor_on, do: cursor_style())), text(after_cursor)] ++ hint
    )
  end

  defp cursor_style, do: Style.new(fg: :black, bg: :yellow)
  defp placeholder_style, do: Style.new(attrs: [:dim])

  # A pending risk marker goes in the gutter of the next complete line that is not a state line
  # (`· ask_human`): the command, or the review asking about it.
  defp mark(lines, %{marker: {color, small}} = state) do
    case Enum.find_index(lines, &(not (&1 |> String.trim_leading() |> String.starts_with?("·")))) do
      nil ->
        {lines, state}

      i ->
        marked = {:marked, color, small, lines |> Enum.at(i) |> String.trim_leading()}
        {List.replace_at(lines, i, marked), %{state | marker: nil}}
    end
  end

  defp mark(lines, state), do: {lines, state}

  @doc false
  def line_node({:marked, color, small, text}),
    do: stack(:horizontal, [text("●", Style.new(fg: color)), text(small, Style.new(attrs: [:dim])), text(" " <> text)])

  def line_node(text) when is_binary(text), do: text(text)

  defp visible(state, height) do
    lines = state.lines ++ if(state.partial == "", do: [], else: [state.partial])
    wrapped = Enum.flat_map(lines, &wrap(&1, state.width))

    shown =
      wrapped
      |> Enum.drop(-min(state.scroll, max(length(wrapped) - height, 0)))
      |> Enum.take(-height)

    shown ++ List.duplicate("", height - length(shown))
  end

  @doc false
  def status_line(state) do
    elapsed =
      if state.started,
        do: " · #{Float.round((now() - state.started) / 1000, 1)} s",
        else: ""

    scroll = if state.scroll > 0, do: " · scrolled", else: ""
    tier = if state.tier, do: " · tier #{state.tier}", else: ""
    cost = if state.usd > 0, do: " · $#{Float.round(state.usd, 4)}", else: ""

    " state #{state.leaf}#{elapsed}#{tier} · #{state.decisions} decisions#{cost}#{waiting_for(state)}#{scroll}"
  end

  defp waiting_for(%{waiting: true}), do: " · review: y / n"
  defp waiting_for(%{paused: true}), do: " · paused: Enter steps"
  defp waiting_for(_state), do: ""

  # A marked line wraps after its gutter; its continuation lines are indented to match.
  defp wrap({:marked, color, small, text}, width) do
    gutter = 2 + String.length(small)
    [first | rest] = wrap(text, max(width - gutter, 1))
    [{:marked, color, small, first} | Enum.map(rest, &(String.duplicate(" ", gutter) <> &1))]
  end

  defp wrap("", _width), do: [""]

  defp wrap(line, width) when width > 0 do
    line
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp pad(text, width), do: text |> String.slice(0, width) |> String.pad_trailing(width)

  defp border(width), do: text(String.duplicate("─", width), Style.new(attrs: [:dim]))

  defp header_style, do: Style.new(attrs: [:reverse])
  defp bar_style, do: Style.new(fg: :cyan)

  defp status_style(%{waiting: true}), do: Style.new(fg: :black, bg: :yellow)
  defp status_style(_state), do: Style.new(attrs: [:dim])

  defp short(nil), do: nil
  defp short(module), do: module |> to_string() |> String.split(".") |> List.last()

  defp now, do: System.monotonic_time(:millisecond)
end
