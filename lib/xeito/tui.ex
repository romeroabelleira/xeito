defmodule Xeito.Tui do
  @moduledoc """
  The terminal UI: a client of `xeitod` in the Elm architecture of TermUI
  (`docs/architecture/07-harness-frontend.md`, `docs/architecture/08-tech-stack.md#the-tui-the-weakest-link`).

      ┌ xeito · ~/src/shop · FixFailingTest ─────────────────────────────┐
      │ transcript (Xeito.Client.Render): intent, decisions, tool calls,  │
      │ streamed model output                                             │
      │ > prompt                                                          │
      │ state verifying · 14.2 s · 3 decisions · review: y/n              │
      └───────────────────────────────────────────────────────────────────┘

  A toggleable **status bar** (Ctrl-T, or `/statusbar`; segments with `/statusbar show|hide`,
  saved in `Xeito.Client.Config`) adds two lines: GPU, model services and
  CPU from the daemon's `Xeito.Monitor`, and the session's usage, determinism budget, spend and
  queues (`Xeito.Client.StatusBar`). While it is hidden, the daemon does not poll for it.

  `/quit` (or `/exit`, Ctrl-D, Ctrl-C) closes the TUI; the session keeps running in the daemon.

  The prompt's cursor blinks like an editor's: solid while you type, blinking in between, and
  solid again (with no timer running) after 10 s without a key.

  Keys: Enter sends (and steps a paused run when the prompt is empty); `y` / `n` answer a
  pending review when the prompt is empty; PgUp / PgDn
  scroll; Ctrl-C or Ctrl-D quit (the session keeps running in the daemon and can be reattached
  with `--session`).

  The TUI owns no run state: everything shown comes from daemon events, so it can crash, be
  closed or be replaced without touching the runs.
  """

  use TermUI.Elm

  alias TermUI.Event
  alias TermUI.Renderer.Style
  alias TermUI.Widgets.TextInput
  alias Xeito.Client
  alias Xeito.Client.Config
  # --- init ----------------------------------------------------------------------------------
  alias Xeito.Client.Render
  alias Xeito.Client.StatusBar

  @max_lines 5_000
  # Blink half-period and how long the cursor keeps blinking after the last key (as GTK does), so
  # an idle TUI stops waking up.
  @blink_ms 530
  @blink_for_ms 10_000

  @impl true
  def init(_runtime_opts) do
    opts = Application.get_env(:xeito, :tui, [])
    {:ok, client} = Client.connect(Keyword.fetch!(opts, :socket))

    {session, status} = open(client, opts)
    {rows, cols} = TermUI.Platform.terminal_size()
    earlier = if opts[:session], do: earlier_turns(client, session), else: []
    prefs = Config.load()
    {:ok, input} = TextInput.init(TextInput.new(placeholder: "ask, or /help", width: cols - 2))

    %{
      client: client,
      session: session,
      cwd: status["cwd"] || opts[:cwd],
      lines: earlier ++ ["session #{session} · /help · y/n answer a review · /quit"],
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
      monitor: nil,
      workspace: nil,
      workspace_at: nil,
      usage: StatusBar.new(),
      cursor_on: true,
      blink: 0,
      blink_until: 0
    }
    |> wake_cursor()
    |> tap(&if(&1.bar, do: Client.request(client, %{"cmd" => "monitor", "on" => true})))
    |> tap(&Client.request(client, %{"cmd" => "workspace", "session" => &1.session}))
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
        # --- events → messages ---------------------------------------------------------------------
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

  @impl true
  def event_to_msg(%Event.Key{key: key, modifiers: mods}, _state)
      when key in [:c, "c", :d, "d", :t, "t"] and is_list(mods) and mods != [] do
    cond do
      :ctrl not in mods -> :ignore
      key in [:t, "t"] -> {:msg, :toggle_bar}
      true -> {:msg, :quit}
    end
  end

  def event_to_msg(%Event.Key{key: :enter}, _state), do: {:msg, :submit}
  def event_to_msg(%Event.Key{key: :page_up}, _state), do: {:msg, {:scroll, 10}}
  def event_to_msg(%Event.Key{key: :page_down}, _state), do: {:msg, {:scroll, -10}}

  def event_to_msg(%Event.Key{char: char} = event, state) when char in ["y", "n"] do
    if state.waiting and TextInput.get_value(state.input) == "",
      do: {:msg, {:review, char}},
      else: {:msg, {:input, event}}
  end

  def event_to_msg(%Event.Resize{width: w, height: h}, _state), do: {:msg, {:resize, w, h}}
  def event_to_msg(%Event.Key{} = event, _state), do: {:msg, {:input, event}}
  def event_to_msg(_event, _state), do: :ignore

  # Daemon events and request replies arrive as plain process messages.
  # Each monitor tick also refreshes the workspace (git, budget) if it is older than 10 s.
  def handle_info({:xeito_event, %{"event" => "monitor", "attrs" => snapshot}}, state) do
    if state.workspace_at == nil or now() - state.workspace_at > 10_000,
      do: request(state, %{"cmd" => "workspace", "session" => state.session})

    {%{state | monitor: snapshot, workspace_at: state.workspace_at || now()}, []}
  end

  def handle_info({:xeito_event, %{"event" => "workspace", "attrs" => ws}}, state),
    do: {%{state | workspace: ws, workspace_at: now()}, []}

  def handle_info({:xeito_event, event}, state), do: {apply_event(state, event), []}

  def handle_info({:xeito_reply, %{"ok" => false, "error" => error}}, state), do: {append(state, "✗ #{error}\n"), []}

  # Only the timer of the latest key counts; older ones are stale.
  def handle_info({:blink, gen}, %{blink: gen} = state) do
    if now() < state.blink_until do
      Process.send_after(self(), {:blink, gen}, @blink_ms)
      {%{state | cursor_on: not state.cursor_on}, []}
    else
      {%{state | cursor_on: true}, []}
    end
  end

  def handle_info(_msg, state), do: {state, []}

  # --- update --------------------------------------------------------------------------------

  # Every message here comes from a key, except a resize: a key shows the cursor solid and
  # restarts the blinking phase.
  @impl true
  def update({:resize, _, _} = msg, state), do: handle_update(msg, state)
  def update(msg, state), do: handle_update(msg, wake_cursor(state))

  @doc false
  def wake_cursor(state) do
    gen = state.blink + 1
    Process.send_after(self(), {:blink, gen}, @blink_ms)
    %{state | cursor_on: true, blink: gen, blink_until: now() + @blink_for_ms}
  end

  defp handle_update(:quit, state), do: {state, [TermUI.Command.quit(:normal)]}

  defp handle_update(:submit, state) do
    case String.trim(TextInput.get_value(state.input)) do
      "" when state.paused ->
        request(state, %{"cmd" => "prompt", "session" => state.session, "text" => "/next"})
        {%{state | paused: false}, []}

      "" ->
        {state, []}

      # Handled here: it changes how this client shows things, never what runs.
      quit when quit in ["/quit", "/exit"] ->
        handle_update(:quit, state)

      "/statusbar" <> args ->
        handle_update({:statusbar, args}, state)

      text ->
        request(state, %{"cmd" => "prompt", "session" => state.session, "text" => text})
        {append(%{state | input: TextInput.clear(state.input), scroll: 0}, "> #{text}\n"), []}
    end
  end

  defp handle_update({:review, answer}, state) do
    # --- status bar preferences ----------------------------------------------------------
    cmd = if answer == "y", do: "approve", else: "deny"
    request(state, %{"cmd" => cmd, "session" => state.session})

    {append(%{state | waiting: false}, "  #{if answer == "y", do: "approved", else: "denied"}\n"), []}
  end

  defp handle_update(:toggle_bar, state), do: {set_bar(state, not state.bar), []}

  defp handle_update({:statusbar, args}, state) do
    state = %{state | input: TextInput.clear(state.input)}
    {statusbar(String.split(args, ~r/[\s,]+/, trim: true), state), []}
  end

  defp handle_update({:input, event}, state) do
    {:ok, input} = TextInput.handle_event(event, state.input)
    {%{state | input: input}, []}
  end

  defp handle_update({:scroll, n}, state), do: {%{state | scroll: max(state.scroll + n, 0)}, []}

  defp handle_update({:resize, w, h}, state),
    do: {%{state | width: w, height: h, input: Map.put(state.input, :width, w - 2)}, []}

  defp handle_update(_msg, state), do: {state, []}

  defp set_bar(state, bar) do
    request(state, %{"cmd" => "monitor", "on" => bar})
    %{state | bar: bar, monitor: if(bar, do: state.monitor)}
  end

  defp statusbar([], state), do: state |> set_bar(not state.bar) |> save_prefs()
  defp statusbar(["on"], state), do: state |> set_bar(true) |> save_prefs()
  defp statusbar(["off"], state), do: state |> set_bar(false) |> save_prefs()
  defp statusbar(["reset"], state), do: save_prefs(%{set_bar(state, true) | hidden: []})

  defp statusbar([verb | names], state) when verb in ["show", "hide"] and names != [] do
    case names -- StatusBar.segments() do
      [] ->
        hidden =
          if verb == "hide",
            do: Enum.uniq(state.hidden ++ names),
            else: state.hidden -- names

        save_prefs(%{state | hidden: hidden})

      unknown ->
        append(state, "✗ unknown segment #{Enum.join(unknown, ", ")}; see /statusbar segments\n")
    end
  end

  defp statusbar(["segments"], state) do
    # --- daemon events -------------------------------------------------------------------------
    listed =
      Enum.map_join(StatusBar.segments(), " ", fn seg ->
        if seg in state.hidden, do: "·#{seg}", else: seg
      end)

    append(
      state,
      "status bar #{if state.bar, do: "on", else: "off"} · segments: #{listed} (· hidden)\n"
    )
  end

  defp statusbar(_args, state) do
    append(
      state,
      "/statusbar [on|off|reset|segments] · /statusbar show|hide <segment>[,<segment>]\n"
    )
  end

  # Preferences are saved on every change; a failed write keeps them for this session only.
  defp save_prefs(state) do
    prefs =
      put_in(state.prefs, ["status_bar"], %{"visible" => state.bar, "hidden" => state.hidden})

    case Config.save(prefs) do
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

  @doc false
  def apply_event(state, %{"event" => type} = event) do
    %{state | usage: StatusBar.count(state.usage, event)}
    |> track(type, event)
    |> append(Render.line(event))
  end

  defp track(state, "run_selected", %{"attrs" => a}),
    do: %{state | machine: short(a["machine"]), started: now(), decisions: 0, usd: 0.0}

  # --- view ----------------------------------------------------------------------------------
  defp track(state, "state_entered", %{"run" => run, "attrs" => %{"state" => leaf}}) do
    if internal?(run), do: state, else: %{state | leaf: to_string(leaf)}
  end

  defp track(state, "decision_made", %{"attrs" => a}) do
    usd = if is_number(a["usd"]), do: a["usd"], else: 0.0
    %{state | decisions: state.decisions + 1, tier: a["actor"], usd: state.usd + usd}
  end

  defp track(state, "intent", %{"attrs" => a}),
    do: %{state | decisions: state.decisions + 1, leaf: "intent", tier: a["actor"]}

  defp track(state, "human_needed", _event), do: %{state | waiting: true}
  defp track(state, "paused", _event), do: %{state | paused: true}

  defp track(state, "turn_finished", _event), do: %{state | leaf: "idle", waiting: false, paused: false, started: nil}

  defp track(state, "disconnected", _event), do: %{state | leaf: "disconnected"}
  defp track(state, _type, _event), do: state

  defp internal?(run), do: String.ends_with?(run, "/esc") or String.ends_with?(run, "/intent")

  # Text arrives in pieces (streamed deltas); complete lines move into the transcript.
  @doc false
  def append(state, ""), do: state

  def append(state, text) do
    [first | rest] = String.split(state.partial <> text, "\n")

    case Enum.split(rest, -1) do
      {[], []} ->
        %{state | partial: first}

      {complete, [partial]} ->
        lines = Enum.take(state.lines ++ [first | complete], -@max_lines)
        %{state | lines: lines, partial: partial}
    end
  end

  @impl true
  def view(state) do
    bar =
      if state.bar,
        do: StatusBar.lines(state.usage, state.monitor, state.workspace, state.hidden),
        else: []

    body_height = max(state.height - 3 - length(bar), 1)

    stack(:vertical, [
      text(
        pad(" xeito · #{state.cwd} · #{state.machine || "ready"}", state.width),
        header_style()
      ),
      stack(:vertical, Enum.map(visible(state, body_height), &text/1)),
      stack(:horizontal, [
        text("> "),
        TextInput.render(input_view(state), %{width: state.width - 2, height: 1})
      ]),
      stack(:vertical, Enum.map(bar, &text(pad(" " <> &1, state.width), bar_style()))),
      text(pad(status_line(state), state.width), status_style(state))
    ])
  end

  # In the blink's off phase the input is drawn from a copy whose cursor row is off-screen, so
  # TextInput draws no cursor cell; the stored input (and typing) is unaffected.
  @doc false
  def input_view(%{cursor_on: true, input: input}), do: input
  def input_view(%{input: input}), do: %{input | cursor_row: -1}

  defp visible(state, height) do
    lines = state.lines ++ if(state.partial == "", do: [], else: [state.partial])
    wrapped = Enum.flat_map(lines, &wrap(&1, state.width))

    shown =
      wrapped
      |> Enum.drop(-min(state.scroll, max(length(wrapped) - height, 0)))
      |> Enum.take(-height)

    shown ++ List.duplicate("", height - length(shown))
  end

  defp status_line(state) do
    elapsed =
      if state.started,
        do: " · #{Float.round((now() - state.started) / 1000, 1)} s",
        else: ""

    review =
      cond do
        state.waiting -> " · review: y / n"
        state.paused -> " · paused: Enter steps"
        true -> ""
      end

    scroll = if state.scroll > 0, do: " · scrolled", else: ""
    tier = if state.tier, do: " · tier #{state.tier}", else: ""
    cost = if state.usd > 0, do: " · $#{Float.round(state.usd, 4)}", else: ""

    " state #{state.leaf}#{elapsed}#{tier} · #{state.decisions} decisions#{cost}#{review}#{scroll}"
  end

  defp wrap("", _width), do: [""]

  defp wrap(line, width) when width > 0 do
    line
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp pad(text, width), do: text |> String.slice(0, width) |> String.pad_trailing(width)

  defp header_style, do: Style.new(attrs: [:reverse])
  defp bar_style, do: Style.new(fg: :cyan)

  defp status_style(%{waiting: true}), do: Style.new(fg: :black, bg: :yellow)
  defp status_style(_state), do: Style.new(attrs: [:dim])

  defp short(nil), do: nil
  defp short(module), do: module |> to_string() |> String.split(".") |> List.last()

  defp now, do: System.monotonic_time(:millisecond)
end
