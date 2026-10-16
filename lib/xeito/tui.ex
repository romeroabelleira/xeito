defmodule Xeito.Tui do
  @moduledoc """
  The terminal UI, a TermUI Elm-architecture client of `xeitod`; it owns no run state.

  The screen is `Xeito.Tui.View`; the transcript and run tracking `Xeito.Tui.Transcript`; editing
  the prompt line `Xeito.Tui.Input`; the cursor and spinner timers `Xeito.Tui.Timers`. This module
  holds the state and wires keys, daemon events, replies and ticks to them.

  Startup: continues the directory's last updated session (or `--session ID`), or starts one,
  showing a banner and the earlier turns. Up/Down start with the directory's earlier prompts.

  Keys:

    * Enter sends; on an empty line it steps a paused run or sends held lines
    * `\\` then Enter, Enter with a modifier, or a paste: new line; the prompt grows to 6 rows
    * `y`/`n` (or `s`/`a` to allow) answers a pending review; other text says what to do instead
    * Esc halts the running turn, or drops held lines
    * Up/Down move between prompt lines, then recall earlier prompts
    * Tab completes `/command`, `/machine <name>`, `/skill:<name>`; repeated Tab cycles
    * Ctrl-J steers the running chat turn (`/steer`); Ctrl-T toggles the status bar
    * PgUp/PgDn scroll; Ctrl-C, Ctrl-D, `/quit`, `/exit` quit, leaving the session in the daemon

  Lines sent while a turn runs are queued in the session; if the turn ends halted, failed or with
  a question, they are held. Own commands: `/statusbar [show|hide]`, `/legend`, `/sessions [N|new]`,
  `/skills <words>` (`Xeito.Tui.SkillSearch`).
  """

  use TermUI.Elm

  alias TermUI.Event
  alias TermUI.Widgets.TextInput
  alias Xeito.Client
  alias Xeito.Client.Config
  alias Xeito.Client.StatusBar
  alias Xeito.Tui.Banner
  alias Xeito.Tui.Input
  alias Xeito.Tui.Sessions
  alias Xeito.Tui.SkillSearch
  alias Xeito.Tui.StatusBarPrefs
  alias Xeito.Tui.Timers
  alias Xeito.Tui.Transcript
  alias Xeito.Tui.View

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
    |> Timers.wake_cursor()
    |> tap(&if(&1.bar, do: Client.request(client, %{"cmd" => "monitor", "on" => true})))
    |> tap(&Client.request(client, %{"cmd" => "workspace", "session" => &1.session}))
  end

  @doc """
  An idle TUI state for a session.

  Options: `client`, `session`, `cwd`, `size` (`{rows, cols}`), `earlier` (transcript lines),
  `continued`, `prompt_history` (newest first), `prefs`, `prefs_file`, and `status_bar`
  (overrides the preferences' visibility).
  """
  @spec new(keyword()) :: map()
  def new(opts) do
    {rows, cols} = Keyword.fetch!(opts, :size)
    prefs = Keyword.fetch!(opts, :prefs)
    {:ok, input} = TextInput.init(TextInput.new(placeholder: View.placeholder(), width: cols - 2, multiline: true))
    session = Keyword.fetch!(opts, :session)

    %{
      client: Keyword.fetch!(opts, :client),
      session: session,
      cwd: opts[:cwd],
      lines:
        Keyword.get(opts, :earlier, []) ++
          Banner.banner(opts[:cwd]) ++ [Banner.header(session, Keyword.get(opts, :continued, false))],
      partial: "",
      live: [],
      live_partial: "",
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
      # `{colour, confidence}` of a Risk decision waiting for the line it marks.
      marker: nil,
      blink: 0,
      frame: 0,
      queue: [],
      held: false,
      spin_gen: 0,
      spinning: false,
      blink_until: 0,
      # history_index -1 is the line being typed, kept in history_draft while recalling.
      prompt_history: Keyword.get(opts, :prompt_history, []),
      history_index: -1,
      history_draft: "",
      # `{candidates, shown_index}` while Tab cycles.
      completion: nil,
      listed: []
    }
  end

  defp open(client, opts) do
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

  defp earlier_turns(client, session, cwd) do
    case Client.request(client, %{"cmd" => "transcript", "session" => session, "cwd" => cwd}) do
      %{"ok" => true, "turns" => turns} -> Banner.transcript_lines(turns)
      _ -> []
    end
  end

  defp earlier_prompts(client, cwd) do
    case Client.request(client, %{"cmd" => "prompts", "cwd" => cwd}) do
      %{"ok" => true, "prompts" => prompts} -> prompts
      _ -> []
    end
  end

  # --- events → messages ---------------------------------------------------------------------

  @impl true
  def event_to_msg(%Event.Key{} = key, state), do: key_to_msg(key, state)
  def event_to_msg(%Event.Resize{width: w, height: h}, _state), do: {:msg, {:resize, w, h}}
  def event_to_msg(%Event.Paste{content: text}, _state), do: {:msg, {:insert, Input.pasted(text)}}
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

  # Ctrl-J steers because every terminal sends it; TermUI does not report Alt-Enter.
  defp control_key(key, mods) do
    cond do
      :ctrl not in mods -> :ignore
      key in [:t, "t"] -> {:msg, :toggle_bar}
      key in [:j, "j"] -> {:msg, :steer}
      true -> {:msg, :quit}
    end
  end

  # Each monitor tick also refreshes the workspace (git, budget) if it is older than 10 s.
  @spec handle_info(term(), map()) :: {map(), list()}
  def handle_info({:xeito_event, event}, state), do: {on_event(event, state), []}

  def handle_info({:xeito_reply, %{"ok" => false, "error" => error}}, state),
    do: {Transcript.append(state, "✗ #{error}\n"), []}

  def handle_info({:xeito_reply, tag, reply}, state), do: {Sessions.reply(tag, reply, state), []}

  # Only the latest timer generation counts; older ticks are stale.
  def handle_info({timer, gen}, state) when timer in [:blink, :spin], do: {Timers.tick(timer, gen, state), []}
  def handle_info(_msg, state), do: {state, []}

  # After a switch the connection still follows the other session: ignore its events.
  defp on_event(%{"session" => other}, %{session: session} = state) when other != session, do: state
  defp on_event(%{"event" => "monitor", "attrs" => snapshot}, state), do: on_monitor(snapshot, state)
  defp on_event(%{"event" => "workspace", "attrs" => ws}, state), do: %{state | workspace: ws, workspace_at: now()}
  defp on_event(event, state), do: state |> Transcript.apply_event(event) |> Timers.spin()

  defp on_monitor(snapshot, state) do
    if state.workspace_at == nil or now() - state.workspace_at > 10_000,
      do: request(state, %{"cmd" => "workspace", "session" => state.session})

    %{state | monitor: snapshot, workspace_at: state.workspace_at || now()}
  end

  @impl true
  def view(state), do: View.view(state)

  # --- update --------------------------------------------------------------------------------

  # Every message but a resize comes from a key, which wakes the cursor.
  @impl true
  def update({:resize, _, _} = msg, state), do: handle_update(msg, state)
  def update(msg, state), do: handle_update(msg, state |> Timers.wake_cursor() |> keep_completion(msg))

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
  defp line_key(:complete, state), do: {Input.complete(state), []}
  defp line_key(:legend, state), do: {Transcript.legend(state), []}
  defp line_key(:steer, state), do: state.input |> TextInput.get_value() |> String.trim() |> steer(state)

  defp keep_completion(state, :complete), do: state
  defp keep_completion(state, _msg), do: %{state | completion: nil}

  defp enter(state) do
    if Input.continued?(state.input),
      do: {%{state | input: :input |> Input.edit(%Event.Key{key: :backspace}, state.input) |> Input.insert("\n")}, []},
      else: state.input |> TextInput.get_value() |> String.trim() |> submit(state)
  end

  defp steer("", state), do: {state, []}
  defp steer(text, state), do: send_line("/steer " <> text, Input.remember(state, text))

  defp submit("", %{paused: true} = state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/next"})
    {%{state | paused: false}, []}
  end

  defp submit("", %{held: reason, queue: [_ | _]} = state) when is_binary(reason) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/send"})
    {state, []}
  end

  defp submit("", state), do: {state, []}
  defp submit(text, state), do: run_line(text, Input.remember(state, text))

  @review_answers %{
    "y" => {%{"cmd" => "approve"}, "approved"},
    "n" => {%{"cmd" => "deny"}, "denied"},
    "s" => {%{"cmd" => "approve", "allow" => "session"}, "approved for this session"},
    "a" => {%{"cmd" => "approve", "allow" => "always"}, "approved, always"}
  }

  defp review(answer, state) do
    {req, said} = Map.fetch!(@review_answers, answer)
    request(state, Map.put(req, "session", state.session))
    {Transcript.append(%{state | waiting: false}, "  #{said}\n"), []}
  end

  defp move_or_recall(direction, state) do
    if within?(state.input, direction),
      do: screen_update({:input, %Event.Key{key: arrow(direction)}}, state),
      else: state |> Input.recall(direction) |> recalled(state)
  end

  defp within?(input, :older), do: input.cursor_row > 0
  defp within?(input, :newer), do: input.cursor_row < length(input.lines) - 1

  defp arrow(:older), do: :up
  defp arrow(:newer), do: :down

  defp recalled({:ok, text, state}, _state), do: {%{state | input: Input.put_text(state.input, text)}, []}
  defp recalled(:none, state), do: {state, []}

  defp halt(%{leaf: "idle", held: reason, queue: [_ | _]} = state) when is_binary(reason) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/drop"})
    {state, []}
  end

  defp halt(%{leaf: leaf} = state) when leaf in ["idle", "disconnected"], do: {state, []}

  defp halt(state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/halt"})
    {state, []}
  end

  defp screen_update(:toggle_bar, state), do: {StatusBarPrefs.set_bar(state, not state.bar), []}

  defp screen_update({:statusbar, args}, state) do
    state = %{state | input: TextInput.clear(state.input)}
    {StatusBarPrefs.command(String.split(args, ~r/[\s,]+/, trim: true), state), []}
  end

  defp screen_update({edit, arg}, state) when edit in [:input, :insert],
    do: {%{state | input: Input.edit(edit, arg, state.input)}, []}

  defp screen_update({:scroll, n}, state), do: {%{state | scroll: max(state.scroll + n, 0)}, []}

  defp screen_update({:resize, w, h}, state),
    do: {%{state | width: w, height: h, input: Map.put(state.input, :width, w - 2)}, []}

  defp screen_update(_msg, state), do: {state, []}

  @doc "Sends a request to the daemon from a task, so the UI never waits; the reply arrives as `{:xeito_reply, reply}`."
  @spec request(map(), map()) :: {:ok, pid()}
  def request(state, req) do
    me = self()
    Task.start(fn -> send(me, {:xeito_reply, Client.request(state.client, req)}) end)
  end

  # --- the prompt line -----------------------------------------------------------------------

  # During a review, any other text goes to the daemon as a prompt, which takes it as the answer.
  defp run_line(answer, %{waiting: true} = state) when answer in ["y", "n", "s", "a"],
    do: handle_update({:review, answer}, %{state | input: TextInput.clear(state.input)})

  defp run_line("/" <> command = line, state) do
    case own_command(command) do
      nil -> send_line(line, state)
      msg -> handle_update(msg, state)
    end
  end

  defp run_line(text, %{waiting: true} = state) do
    request(state, %{"cmd" => "prompt", "session" => state.session, "text" => text})
    state = %{state | input: TextInput.clear(state.input), waiting: false}
    {Transcript.append(state, "  instead: #{View.one_line(text)}\n"), []}
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
    state = %{state | input: TextInput.clear(state.input), scroll: 0}
    {Transcript.append(state, "> #{String.replace(text, "\n", "\n  ")}\n"), []}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
