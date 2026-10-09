defmodule Xeito.Tui do
  @moduledoc """
  The terminal UI: a client of `xeitod` in the Elm architecture of TermUI
  (`docs/architecture/07-harness-frontend.md`, `docs/architecture/08-tech-stack.md#the-tui-the-weakest-link`).

      ┌ xeito · FixFailingTest ───────────────────────────────────────────┐
      │ transcript (Xeito.Client.Render): intent, decisions, tool calls,  │
      │ streamed model output                                             │
      │ ───────────────────────────────────────────────────────────────── │
      │ > prompt                                                          │
      │ ───────────────────────────────────────────────────────────────── │
      │ ◆ state verifying · 14.2 s · review: y/n        ~/src/shop (main) │
      └───────────────────────────────────────────────────────────────────┘

  A toggleable **status bar** (Ctrl-T, or `/statusbar`; segments with `/statusbar show|hide`,
  saved in `Xeito.Client.Config`) adds one line, above the status line: GPU, model services and
  CPU from the daemon's `Xeito.Monitor`, and the session's usage, determinism budget, spend and
  queues (`Xeito.Client.StatusBar`). While it is hidden, the daemon does not poll for it.

  `/quit` (or `/exit`, Ctrl-D, Ctrl-C) closes the TUI; the session keeps running in the daemon.

  Started in a directory, the TUI continues that directory's last updated session (live in the
  daemon, or rebuilt from the log) with its earlier turns (each prompt, the first line of each
  answer, the last answer in full), or starts one if there is none;
  `--session ID` opens a given one. `/sessions` lists the directory's sessions, last updated
  first; `/sessions N` switches to one, `/sessions new` starts another. Above the session line,
  a banner shows the keys, example prompts, the machines, the first lines of the workspace's
  `AGENTS.md`, and its skills by name (the user's own are only counted). Up / Down start out
  with the prompts typed in the directory before, from every session there.

  The status line starts with a marker: `○` idle, a spinner while the session works, `◆` (on
  a highlighted line) when it waits for you, `✗` without a daemon. Like the cursor, the
  spinner's timer runs only while there is work. At its right end, where commands run: the
  workspace, shortened from the left, and its git branch.

  The prompt's cursor blinks like an editor's: solid while you type, blinking in between, and
  solid again (with no timer running) after 10 s without a key.

  Keys: Enter sends (and steps a paused run when the prompt is empty); `\\` then Enter starts a
  new line in its place (so does Enter with a modifier, where the terminal reports one), and a
  paste keeps its lines (bracketed paste, turned on by `mix xeito.tui`): the prompt grows to 6
  rows, then scrolls with the cursor; a pending review is answered with `y` or `n` and Enter, or with text saying what to do instead; Esc halts the
  running turn; Up / Down move between the prompt's lines, and past its first or last recall
  earlier prompts (the line being typed comes back past the newest); Tab completes a `/command`, a machine after `/machine ` or a skill after `/skill:`
  (by name, then by what the typed words describe), and each further Tab shows the next match;
  `/skills <words>` lists the skills those words describe (`Xeito.Tui.SkillSearch`); a line sent while a turn runs is queued in the
  session and shown above the prompt, and when the turn ended in a way it was not written for
  (halted, failed, stopped, a question) it is held: Enter on an empty line sends it, Esc drops it;
  Ctrl-J sends the typed line into the running chat turn instead, for its next model call
  (`/steer`); PgUp / PgDn scroll; Ctrl-C or Ctrl-D quit (the
  session keeps running in the daemon, and the next start in this directory continues it).

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
  alias Xeito.Session.Router
  alias Xeito.Tui.Sessions
  alias Xeito.Tui.SkillSearch

  @max_lines 5_000
  # Blink half-period and how long the cursor keeps blinking after the last key (as GTK does), so
  # an idle TUI stops waking up.
  @blink_ms 530
  @blink_for_ms 10_000
  # The working marker: a spinner, one frame per tick while the session works.
  @spin_ms 100
  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  # The workspace in the status line is shortened from the left to about this many characters.
  @place_max 30
  @placeholder "ask, or /help"
  # The prompt grows a row per line up to this many, then scrolls with the cursor.
  @prompt_rows 6

  # The TUI's own commands (run_line/2); Tab completes them along with the daemon's.
  @own_commands ~w(quit exit statusbar legend sessions skills)

  # --- init ----------------------------------------------------------------------------------

  @impl true
  def init(_runtime_opts) do
    opts = Application.get_env(:xeito, :tui, [])
    {:ok, client} = Client.connect(Keyword.fetch!(opts, :socket))
    {session, status, continued} = open(client, opts)
    cwd = status["cwd"] || opts[:cwd]

    [
      client: client,
      session: session,
      cwd: cwd,
      size: TermUI.Platform.terminal_size(),
      continued: continued,
      earlier: if(opts[:session] || continued, do: earlier_turns(client, session, cwd), else: []),
      prompt_history: earlier_prompts(client, cwd),
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
  `earlier` transcript lines, whether the session was `continued`, the `prompt_history` for
  Up/Down (newest first), the preferences and the file they are saved in (`prefs`,
  `prefs_file`), and optionally `status_bar` to override the preferences' visibility.
  """
  @spec new(keyword()) :: map()
  def new(opts) do
    {rows, cols} = Keyword.fetch!(opts, :size)
    prefs = Keyword.fetch!(opts, :prefs)
    {:ok, input} = TextInput.init(TextInput.new(placeholder: @placeholder, width: cols - 2, multiline: true))
    session = Keyword.fetch!(opts, :session)

    %{
      client: Keyword.fetch!(opts, :client),
      session: session,
      cwd: opts[:cwd],
      lines:
        Keyword.get(opts, :earlier, []) ++
          banner(opts[:cwd]) ++ [header(session, Keyword.get(opts, :continued, false))],
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
      # The spinner's frame, the generation of its timer, and whether a timer is running.
      frame: 0,
      # Lines typed while a turn ran, queued in the session, and whether the session holds them.
      queue: [],
      held: false,
      spin_gen: 0,
      spinning: false,
      blink_until: 0,
      # Earlier prompts for Up/Down, newest first; the one shown (-1: the line being typed,
      # kept as the draft meanwhile).
      prompt_history: Keyword.get(opts, :prompt_history, []),
      history_index: -1,
      history_draft: "",
      # While Tab cycles through completions: `{candidates, shown}`, the index of the one shown.
      completion: nil,
      # The sessions `/sessions` listed last, by number.
      listed: []
    }
  end

  @doc false
  def header(session, true), do: "continuing session #{session} · /sessions · /help · Esc halts · /quit"
  def header(session, false), do: "session #{session} · /help · Esc halts · /quit"

  @doc false
  # The greeting above the session line: the keys, example prompts, the machines, the first lines
  # of the workspace's AGENTS.md, and its skills by name (the user's are only counted: P4e keeps
  # them out of the model's prompt too). `opts[:home]` is where the user's skills are (tests).
  def banner(cwd, opts \\ []) do
    [
      "Enter sends · \\ Enter new line · Esc halts · Up/Down recall · Tab completes · Ctrl-J steers · Ctrl-T status bar · /help",
      "try: fix the failing test · run the checks · commit these changes · explain this code",
      "machines: #{Enum.join(Enum.sort(Map.keys(Router.machines())), " · ")}"
    ] ++ agents_lines(cwd) ++ skills_lines(cwd, opts) ++ [""]
  end

  defp agents_lines(nil), do: ["no AGENTS.md"]

  defp agents_lines(cwd) do
    path = Path.join(cwd, "AGENTS.md")

    case File.read(path) do
      {:ok, text} -> text |> String.split("\n") |> Enum.reject(&(String.trim(&1) == "")) |> agents_excerpt(path)
      {:error, _} -> ["no AGENTS.md in #{cwd}"]
    end
  end

  # Its first three lines that are not blank, and where the rest is.
  defp agents_excerpt([], path), do: ["AGENTS.md is empty (#{path})"]

  defp agents_excerpt([first | rest], path) do
    more = if length(rest) > 2, do: ["  … (#{path})"], else: []
    ["AGENTS.md: " <> first] ++ Enum.map(Enum.take(rest, 2), &"  #{&1}") ++ more
  end

  defp skills_lines(nil, _opts), do: ["no skills"]

  defp skills_lines(cwd, opts) do
    %{listed: listed} = cwd |> Xeito.Skills.discover(opts) |> Xeito.Skills.for_turn(cwd, "")
    yours = length(Xeito.Skills.discover(cwd, opts)) - length(listed)
    [skills_line(Enum.map(listed, &"/skill:#{&1.name}"), yours, cwd)]
  end

  defp skills_line([], 0, cwd), do: "no skills in #{cwd}"
  defp skills_line([], yours, _cwd), do: "no skills here · #{yours} of yours (/skill: then Tab)"
  defp skills_line(here, 0, _cwd), do: "skills here: " <> Enum.join(here, " · ")

  defp skills_line(here, yours, _cwd),
    do: "skills here: #{Enum.join(here, " · ")} · and #{yours} of yours (/skill: then Tab)"

  defp open(client, opts) do
    # Without a session named, the directory's last updated one, or a new one.
    req =
      case opts[:session] do
        nil -> %{"cmd" => "open", "cwd" => opts[:cwd]}
        id -> %{"cmd" => "attach", "session" => id, "cwd" => opts[:cwd]}
      end

    case Client.request(client, req) do
      %{"ok" => true, "session" => id} = reply ->
        {id, reply["status"] || %{"cwd" => opts[:cwd]}, reply["continued"] == true}

      %{"error" => error} ->
        raise "could not open a session: #{error}"
    end
  end

  # On reattach, the conversation so far, from the log (the runs' details stay there).
  defp earlier_turns(client, session, cwd) do
    case Client.request(client, %{"cmd" => "transcript", "session" => session, "cwd" => cwd}) do
      %{"ok" => true, "turns" => turns} -> transcript_lines(turns)
      _ -> []
    end
  end

  @doc false
  # Each prompt's first line, the first line of each earlier answer, and the last answer in full.
  def transcript_lines(turns) do
    last = length(turns) - 1

    turns
    |> Enum.with_index()
    |> Enum.flat_map(fn {turn, i} ->
      ["> " <> first_line(turn["prompt"] || "")] ++ answer_lines(turn["answer"], i == last)
    end)
  end

  defp answer_lines(answer, _last) when answer in [nil, ""], do: []
  defp answer_lines(answer, true), do: String.split(answer, "\n")
  defp answer_lines(answer, false), do: [first_line(answer)]

  defp earlier_prompts(client, cwd) do
    case Client.request(client, %{"cmd" => "prompts", "cwd" => cwd}) do
      %{"ok" => true, "prompts" => prompts} -> prompts
      _ -> []
    end
  end

  defp first_line(text), do: text |> String.split("\n") |> hd()

  # --- events → messages ---------------------------------------------------------------------

  @impl true
  def event_to_msg(%Event.Key{} = key, state), do: key_to_msg(key, state)
  def event_to_msg(%Event.Resize{width: w, height: h}, _state), do: {:msg, {:resize, w, h}}
  def event_to_msg(%Event.Paste{content: text}, _state), do: {:msg, {:insert, pasted(text)}}
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

  defp key_to_msg(%Event.Key{key: key, modifiers: mods}, _state)
       when key in [:c, "c", :d, "d", :t, "t", :j, "j"] and mods != [], do: control_key(key, mods)

  defp key_to_msg(%Event.Key{key: :tab}, _state), do: {:msg, :complete}
  defp key_to_msg(%Event.Key{key: :enter, modifiers: [_ | _]}, _state), do: {:msg, {:insert, "\n"}}

  defp key_to_msg(%Event.Key{key: key} = event, _state) do
    case Map.get(@keys, key) do
      nil -> {:msg, {:input, event}}
      msg -> {:msg, msg}
    end
  end

  # Ctrl-T toggles the status bar; Ctrl-J steers (a line feed, which every terminal sends; the
  # terminal library does not report Alt-Enter); Ctrl-C and Ctrl-D quit. Other modifiers do nothing.
  defp control_key(key, mods) do
    cond do
      :ctrl not in mods -> :ignore
      key in [:t, "t"] -> {:msg, :toggle_bar}
      key in [:j, "j"] -> {:msg, :steer}
      true -> {:msg, :quit}
    end
  end

  # Daemon events and request replies arrive as plain process messages.
  # Each monitor tick also refreshes the workspace (git, budget) if it is older than 10 s.
  def handle_info({:xeito_event, event}, state), do: {on_event(event, state), []}

  def handle_info({:xeito_reply, %{"ok" => false, "error" => error}}, state), do: {append(state, "✗ #{error}\n"), []}
  def handle_info({:xeito_reply, tag, reply}, state), do: {Sessions.reply(tag, reply, state), []}

  # The cursor's and the spinner's timers. Only the latest timer of each counts; older ones are stale.
  def handle_info({timer, gen}, state) when timer in [:blink, :spin], do: {tick(timer, gen, state), []}
  def handle_info(_msg, state), do: {state, []}

  # After a switch, the other session's events still arrive (the connection follows it): not shown.
  defp on_event(%{"session" => other}, %{session: session} = state) when other != session, do: state
  defp on_event(%{"event" => "monitor", "attrs" => snapshot}, state), do: on_monitor(snapshot, state)
  defp on_event(%{"event" => "workspace", "attrs" => ws}, state), do: %{state | workspace: ws, workspace_at: now()}
  defp on_event(event, state), do: state |> apply_event(event) |> spin()

  defp tick(:blink, gen, %{blink: gen} = state), do: blink(gen, state)
  defp tick(:spin, gen, %{spin_gen: gen} = state), do: spin_tick(gen, state)
  defp tick(_timer, _gen, state), do: state

  defp on_monitor(snapshot, state) do
    if state.workspace_at == nil or now() - state.workspace_at > 10_000,
      do: request(state, %{"cmd" => "workspace", "session" => state.session})

    %{state | monitor: snapshot, workspace_at: state.workspace_at || now()}
  end

  # The spinner's timer starts when work starts and stops itself at the first tick after work
  # stops (idle, or waiting for you), so an idle TUI does not wake up.
  defp spin(%{spinning: false} = state) do
    if working?(state) do
      gen = state.spin_gen + 1
      Process.send_after(self(), {:spin, gen}, @spin_ms)
      %{state | spinning: true, spin_gen: gen}
    else
      state
    end
  end

  defp spin(state), do: state

  defp spin_tick(gen, state) do
    if working?(state) do
      Process.send_after(self(), {:spin, gen}, @spin_ms)
      %{state | frame: state.frame + 1}
    else
      %{state | spinning: false}
    end
  end

  defp working?(state), do: state.leaf not in ["idle", "disconnected"] and not state.waiting and not state.paused

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

  defp handle_update(:submit, state), do: enter(state)
  defp handle_update({:review, answer}, state), do: review(answer, state)
  defp handle_update({:recall, direction}, state), do: move_or_recall(direction, state)

  defp handle_update(msg, state) when msg in [:quit, :halt, :complete, :legend, :steer], do: line_key(msg, state)

  defp handle_update({list, args}, state) when list in [:sessions, :skills],
    do: {list_command(list, args, %{state | input: TextInput.clear(state.input)}), []}

  defp handle_update(msg, state), do: screen_update(msg, state)

  defp list_command(:sessions, args, state), do: Sessions.command(args, state)
  defp list_command(:skills, words, state), do: SkillSearch.command(words, state)

  defp line_key(:quit, state), do: {state, [TermUI.Command.quit(:normal)]}
  defp line_key(:halt, state), do: halt(state)
  defp line_key(:complete, state), do: complete(state)
  defp line_key(:legend, state), do: {legend(state), []}
  defp line_key(:steer, state), do: state.input |> TextInput.get_value() |> String.trim() |> steer(state)

  # Only Tab continues a completion; any other key ends it.
  defp keep_completion(state, :complete), do: state
  defp keep_completion(state, _msg), do: %{state | completion: nil}

  # A line ending in `\` at the cursor goes on in a new line, as in a shell; otherwise Enter sends.
  defp enter(state) do
    if continued?(state.input),
      do: {%{state | input: :input |> edit(%Event.Key{key: :backspace}, state.input) |> insert("\n")}, []},
      else: state.input |> TextInput.get_value() |> String.trim() |> submit(state)
  end

  defp continued?(input), do: input |> before_cursor() |> String.ends_with?("\\")

  # Ctrl-J: the typed line for the running chat turn, at its next model call (`/steer`).
  defp steer("", state), do: {state, []}
  defp steer(text, state), do: send_line("/steer " <> text, remember(state, text))

  # An empty line steps a paused run, and otherwise does nothing.
  defp submit("", %{paused: true} = state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/next"})
    {%{state | paused: false}, []}
  end

  defp submit("", %{held: reason, queue: [_ | _]} = state) when is_binary(reason) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/send"})
    {state, []}
  end

  defp submit("", state), do: {state, []}
  defp submit(text, state), do: run_line(text, remember(state, text))

  defp review(answer, state) do
    {cmd, said} = if answer == "y", do: {"approve", "approved"}, else: {"deny", "denied"}
    request(state, %{"cmd" => cmd, "session" => state.session})
    {append(%{state | waiting: false}, "  #{said}\n"), []}
  end

  # In a prompt of several lines, Up and Down move between its lines; past the first or the last
  # they recall.
  defp move_or_recall(direction, state) do
    if within?(state.input, direction),
      do: screen_update({:input, %Event.Key{key: arrow(direction)}}, state),
      else: state |> recall(direction) |> recalled(state)
  end

  defp within?(input, :older), do: input.cursor_row > 0
  defp within?(input, :newer), do: input.cursor_row < length(input.lines) - 1

  defp arrow(:older), do: :up
  defp arrow(:newer), do: :down

  defp recalled({:ok, text, state}, _state), do: {%{state | input: put_text(state.input, text)}, []}
  defp recalled(:none, state), do: {state, []}

  # Halts the running turn (the daemon's `/halt`); with nothing running, Esc does nothing.
  # With nothing running, Esc drops the first line the session holds.
  defp halt(%{leaf: "idle", held: reason, queue: [_ | _]} = state) when is_binary(reason) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/drop"})
    {state, []}
  end

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

  defp screen_update({edit, arg}, state) when edit in [:input, :insert],
    do: {%{state | input: edit(edit, arg, state.input)}, []}

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

  # A pending review: y or n answers it, other text says what to do instead (the daemon takes a
  # prompt during a review as that answer).
  defp run_line(answer, %{waiting: true} = state) when answer in ["y", "n"],
    do: handle_update({:review, answer}, %{state | input: TextInput.clear(state.input)})

  # The TUI's own commands run here; every other command goes to the daemon.
  defp run_line("/" <> command = line, state) do
    case own_command(command) do
      nil -> send_line(line, state)
      msg -> handle_update(msg, state)
    end
  end

  defp run_line(text, %{waiting: true} = state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => text})
    {append(%{state | input: TextInput.clear(state.input), waiting: false}, "  instead: #{one_line(text)}\n"), []}
  end

  defp run_line(text, state), do: send_line(text, state)

  defp own_command(quit) when quit in ["quit", "exit"], do: :quit
  defp own_command("statusbar" <> args), do: {:statusbar, args}
  defp own_command("legend"), do: :legend
  defp own_command("sessions" <> args), do: {:sessions, String.trim(args)}
  defp own_command("skills" <> args), do: {:skills, String.trim(args)}
  defp own_command(_daemon_command), do: nil

  defp send_line(text, state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => text})
    {append(%{state | input: TextInput.clear(state.input), scroll: 0}, "> #{String.replace(text, "\n", "\n  ")}\n"), []}
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
  defp put_text(input, text), do: input |> TextInput.clear() |> insert(text)

  # A key goes to TextInput; text (a paste, a new line) is inserted here, since TextInput inserts
  # only single characters.
  defp edit(:input, event, input), do: event |> TextInput.handle_event(input) |> elem(1)
  defp edit(:insert, text, input), do: insert(input, text)

  defp insert(input, text) do
    before = before_cursor(input) <> text
    lines = String.split(before, "\n")
    value = Enum.join(Enum.take(input.lines, input.cursor_row), "\n") <> sep(input) <> before <> after_cursor(input)

    %{
      TextInput.set_value(input, value)
      | cursor_row: input.cursor_row + length(lines) - 1,
        cursor_col: String.length(List.last(lines))
    }
  end

  defp sep(%{cursor_row: 0}), do: ""
  defp sep(_input), do: "\n"

  # The cursor's line, before and after the cursor; then the lines below it.
  defp before_cursor(input), do: input.lines |> Enum.at(input.cursor_row) |> String.slice(0, input.cursor_col)

  defp after_cursor(input) do
    [line | below] = Enum.drop(input.lines, input.cursor_row)
    Enum.join([String.slice(line, input.cursor_col..-1//1) | below], "\n")
  end

  @doc false
  # Pasted text, with its line breaks as `\n` and without control characters other than tabs (an
  # escape sequence would be written to the screen as it is).
  def pasted(text), do: text |> String.replace(~r/\r\n?/, "\n") |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, "")

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

  # The completions of a line, in order: a command, a machine after `/machine `, a skill after
  # `/skill:` (`Xeito.Tui.SkillSearch`). Case is ignored.
  defp completions("/machine " <> part, _cwd), do: matching("/machine ", Map.keys(Router.machines()), part)
  defp completions("/skill:" <> part, cwd), do: Enum.map(SkillSearch.completions(part, cwd), &("/skill:" <> &1))
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

  @risk_meanings [
    {"safe", "runs without asking"},
    {"review", "waits for you: y, n, or say what to do instead"},
    {"abstain", "no decider was sure: waits for you too"},
    {"forbidden", "refused, never runs"}
  ]

  # `/legend`: each risk dot in the colour it has on commands, and the small number beside it.
  defp legend(state) do
    dots = for {value, meaning} <- @risk_meanings, do: {:marked, @risk_colors[value], "", "#{value} · #{meaning}"}
    number = {:marked, @risk_colors["safe"], superscript(94), "the small number · how sure the decider was, in percent"}
    lines = ["Risk: the dot beside each command"] ++ dots ++ [number, ""]
    %{state | input: TextInput.clear(state.input), lines: Enum.take(state.lines ++ lines, -@max_lines)}
  end

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
  defp track(state, type, event) when type in ["queued", "dequeued", "queue_held"], do: queued(state, type, event)
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

  # The session's queue of lines typed while a turn ran (`Xeito.Session`).
  defp queued(state, "queued", %{"attrs" => %{"text" => text}}), do: %{state | queue: state.queue ++ [text]}
  defp queued(state, "queue_held", %{"attrs" => %{"reason" => reason}}), do: %{state | held: reason}

  defp queued(state, "dequeued", _event) do
    queue = Enum.drop(state.queue, 1)
    %{state | queue: queue, held: queue != [] and state.held}
  end

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

    queued = queue_rows(state)
    prompt = prompt_lines(state, state.width)
    # The header, the queue, the prompt between its two borders, the bar and the status line.
    body_height = max(state.height - 4 - length(prompt) - length(bar) - length(queued), 1)

    stack(:vertical, [
      text(
        pad(" xeito · #{state.machine || "ready"}", state.width),
        header_style()
      ),
      stack(:vertical, Enum.map(visible(state, body_height), &line_node/1)),
      stack(:vertical, Enum.map(queued, &text(pad(&1, state.width), Style.new(attrs: [:dim])))),
      border(state.width),
      stack(:vertical, prompt),
      border(state.width),
      stack(:vertical, Enum.map(bar, &text(pad(" " <> &1, state.width), bar_style()))),
      text(status_line(state, state.width), status_style(state))
    ])
  end

  # Lines typed while a turn ran, above the prompt: queued, or held (with how to send or drop).
  defp queue_rows(%{queue: []}), do: []
  defp queue_rows(%{held: false, queue: queue}), do: Enum.map(queue, &" ⏸ queued: #{one_line(&1)}")

  defp queue_rows(%{held: reason, queue: [first | rest]}),
    do: [
      " ⏸ held (#{held_because(reason)}): #{one_line(first)} · Enter sends · Esc drops"
      | Enum.map(rest, &" ⏸ held: #{one_line(&1)}")
    ]

  # A prompt of several lines, in one row: its first line, and how many more.
  defp one_line(text) do
    case String.split(text, "\n") do
      [line] -> line
      [line | more] -> "#{line} (+#{length(more)} lines)"
    end
  end

  defp held_because("question"), do: "the turn asked you something"
  defp held_because("stopped"), do: "the turn stopped at its step limit"
  defp held_because(status), do: "the turn #{status}"

  @doc "How many rows the prompt grows to before it scrolls."
  @spec prompt_rows() :: pos_integer()
  def prompt_rows, do: @prompt_rows

  @doc false
  # The prompt, a row per line after its mark: `> ` on the first, and an arrow where lines above
  # or below are out of sight. Past `@prompt_rows` lines, the rows shown follow the cursor.
  def prompt_lines(state, width) do
    %{lines: lines, cursor_row: row} = state.input
    first = max(row - (@prompt_rows - 1), 0)
    last = min(first + @prompt_rows, length(lines)) - 1

    for i <- first..last do
      line =
        if i == row, do: input_line(state, width - 2), else: text(String.slice(shown(Enum.at(lines, i)), 0, width - 2))

      stack(:horizontal, [text(mark(i, first, last, length(lines))), line])
    end
  end

  defp mark(0, _first, _last, _count), do: "> "
  defp mark(i, i, _last, _count), do: "↑ "
  defp mark(i, _first, i, count) when i < count - 1, do: "↓ "
  defp mark(_i, _first, _last, _count), do: "  "

  # A tab takes one cell, so the cursor's column is the character's.
  defp shown(line), do: String.replace(line, "\t", " ")

  # The cursor's line is drawn here; TermUI's TextInput keeps the text and handles editing. Its
  # own cursor (reverse video) was easy to miss, and its style cannot be changed, so the typing
  # position is a solid block in a colour nothing else on screen uses. In the blink's off phase
  # the cell is drawn plain. A long line scrolls so the cursor stays visible; an empty prompt
  # shows the placeholder, dimmed, after the cursor.

  @doc false
  def input_line(state, width) do
    value = state.input.lines |> Enum.at(state.input.cursor_row) |> shown()
    col = min(state.input.cursor_col, String.length(value))
    start = max(col - (width - 1), 0)
    shown = String.slice(value, start, width)
    {before, rest} = String.split_at(shown, col - start)
    {at, after_cursor} = if rest == "", do: {" ", ""}, else: String.split_at(rest, 1)

    hint =
      if TextInput.get_value(state.input) == "",
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

  @doc """
  The status line, `width` columns: the working marker, the run's state, and at the right end
  the workspace (shortened from the left) with its git branch. When it does not all fit, the
  state gives way.
  """
  def status_line(state, width) do
    right = " #{place(state)} "
    left = " #{marker(state)} " <> run_status(state)
    fit(left, max(width - String.length(right), 1)) <> right
  end

  defp fit(text, room) do
    if String.length(text) <= room, do: String.pad_trailing(text, room), else: String.slice(text, 0, room - 1) <> "…"
  end

  # Idle, working (the spinner), waiting for you (a review or a paused step), or disconnected.
  defp marker(%{leaf: "disconnected"}), do: "✗"
  defp marker(%{waiting: waiting, paused: paused}) when waiting or paused, do: "◆"
  defp marker(%{leaf: "idle"}), do: "○"
  defp marker(state), do: Enum.at(@frames, rem(state.frame, length(@frames)))

  defp run_status(state) do
    elapsed =
      if state.started,
        do: " · #{Float.round((now() - state.started) / 1000, 1)} s",
        else: ""

    scroll = if state.scroll > 0, do: " · scrolled", else: ""
    tier = if state.tier, do: " · tier #{state.tier}", else: ""
    cost = if state.usd > 0, do: " · $#{Float.round(state.usd, 4)}", else: ""

    "state #{state.leaf}#{elapsed}#{tier} · #{state.decisions} decisions#{cost}#{waiting_for(state)}#{scroll}"
  end

  # Where commands run: the workspace, with `~` for the home directory, and its git branch.
  defp place(state) do
    branch = get_in(state.workspace || %{}, ["git", "branch"])
    short_path(state.cwd) <> if(branch, do: " (#{branch})", else: "")
  end

  defp short_path(path) do
    home = System.user_home() || "/nonexistent"

    path =
      if path == home or String.starts_with?(path, home <> "/"),
        do: "~" <> String.replace_prefix(path, home, ""),
        else: path

    if String.length(path) <= @place_max, do: path, else: shorten(path)
  end

  # The last directories that fit, after `…/` (or `~/…/` under the home directory).
  defp shorten(path) do
    lead = if String.starts_with?(path, "~/"), do: "~/…/", else: "…/"

    path
    |> Path.split()
    |> Enum.reverse()
    |> Enum.reduce_while([], fn part, kept ->
      if kept == [] or String.length(lead <> Path.join([part | kept])) <= @place_max,
        do: {:cont, [part | kept]},
        else: {:halt, kept}
    end)
    |> then(&(lead <> Path.join(&1)))
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

  defp status_style(%{waiting: waiting, paused: paused}) when waiting or paused, do: Style.new(fg: :black, bg: :yellow)
  defp status_style(_state), do: Style.new(attrs: [:dim])

  defp short(nil), do: nil
  defp short(module), do: module |> to_string() |> String.split(".") |> List.last()

  defp now, do: System.monotonic_time(:millisecond)
end
