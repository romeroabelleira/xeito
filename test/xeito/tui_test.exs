defmodule Xeito.TuiTest do
  use ExUnit.Case, async: true

  alias TermUI.Component.RenderNode
  alias TermUI.Event
  alias TermUI.Widgets.TextInput
  alias Xeito.Client.Config
  alias Xeito.Client.StatusBar
  alias Xeito.Tui

  defp state do
    {:ok, input} = TextInput.init(TextInput.new(width: 20))
    %{input: TextInput.set_focused(input, true), cursor_on: true, blink: 0, blink_until: 0}
  end

  defp cursor_drawn?(state), do: state |> Tui.input_line(20) |> inspect() =~ "bg: :yellow"

  defp typed(state, text) do
    Enum.reduce(String.graphemes(text), state, fn c, st ->
      {:ok, input} = TextInput.handle_event(%TermUI.Event.Key{key: c, char: c}, st.input)
      %{st | input: input}
    end)
  end

  test "the cursor blinks after a key, and stops blinking (solid) once idle" do
    state = Tui.wake_cursor(state())
    gen = state.blink
    assert cursor_drawn?(state)

    assert_receive {:blink, ^gen}, 1_000
    {off, []} = Tui.handle_info({:blink, gen}, state)
    refute off.cursor_on
    refute cursor_drawn?(off)
    # The off phase hides only the drawn cursor, never the stored one.
    assert off.input == state.input

    assert_receive {:blink, ^gen}, 1_000
    {on, []} = Tui.handle_info({:blink, gen}, off)
    assert on.cursor_on
    assert_receive {:blink, ^gen}, 1_000

    # Past the blinking period the cursor stays solid and no timer is scheduled.
    # (Monotonic time can be negative, so "past" is relative to now.)
    past = System.monotonic_time(:millisecond) - 1
    {idle, []} = Tui.handle_info({:blink, gen}, %{off | blink_until: past})
    assert idle.cursor_on
    refute_receive {:blink, _}, 700
  end

  test "the input line draws a block cursor at the typing position and scrolls to keep it visible" do
    st = typed(state(), "hello")
    line = inspect(Tui.input_line(st, 20))
    # The block sits after the text, on a space; an empty line shows the dimmed placeholder.
    assert line =~ ~s(content: "hello") and line =~ "bg: :yellow"
    assert inspect(Tui.input_line(state(), 20)) =~ "ask, or /help"

    long = typed(state(), String.duplicate("x", 30) <> "END")
    shown = long |> Tui.input_line(20) |> inspect()
    assert shown =~ "END" and not (shown =~ String.duplicate("x", 20))
  end

  defp session_state do
    Map.merge(state(), %{
      usage: StatusBar.new(),
      lines: [],
      partial: "",
      marker: nil,
      decisions: 0,
      tier: nil,
      usd: 0.0,
      leaf: "idle",
      waiting: false
    })
  end

  test "a risk decision marks the line it applies to with a coloured dot and its confidence" do
    decision = %{
      "event" => "decision_made",
      "run" => "ses-x/t1",
      "attrs" => %{
        "decision_type" => "Xeito.Decisions.Risk",
        "value" => "review",
        "actor" => "large",
        "confidence" => 0.94
      }
    }

    state =
      session_state()
      |> Tui.apply_event(decision)
      |> Tui.apply_event(%{"event" => "state_entered", "run" => "ses-x/t1", "attrs" => %{"state" => "ask_human"}})
      |> Tui.apply_event(%{
        "event" => "effect_requested",
        "run" => "ses-x/t1",
        "attrs" => %{"kind" => "bash", "args" => %{"cmd" => "rm -rf _build"}}
      })

    # No line of its own; the state line stays plain; the command carries the marker.
    assert [_state_line, {:marked, :yellow, "⁹⁴", "$ rm -rf _build"}] = state.lines
    refute Enum.any?(state.lines, &(is_binary(&1) and &1 =~ "risk"))
  end

  test "the status bar is one line, filled by priority up to the width" do
    usage = StatusBar.new()
    line = StatusBar.line(usage, nil, nil, [], 40)
    assert String.length(line) <= 40 and line =~ "tok"
    refute line =~ "\n"
    assert String.length(StatusBar.line(usage, nil, nil, [], 200)) > 40
    assert StatusBar.line(usage, nil, nil, StatusBar.segments(), 80) == ""
  end

  test "in the blink's off phase the cursor cell is drawn plain" do
    st = typed(state(), "ab")
    assert cursor_drawn?(st)
    refute cursor_drawn?(%{st | cursor_on: false})
    assert inspect(Tui.input_line(%{st | cursor_on: false}, 20)) =~ ~s(content: "ab")
  end

  test "a marked line renders a coloured dot, a dim superscript and the text" do
    node = inspect(Tui.line_node({:marked, :red, "¹⁰⁰", "$ rm -rf /"}))
    assert node =~ ~s(content: "●") and node =~ "fg: :red"
    assert node =~ ~s(content: "¹⁰⁰") and node =~ ":dim"
    assert node =~ ~s(content: " $ rm -rf /")
  end

  test "the status bar keeps the higher-priority segment when two do not fit" do
    usage = StatusBar.new()
    only = StatusBar.segments() -- ~w(calls tokens)
    both = StatusBar.line(usage, nil, nil, only, 200)
    assert both =~ "no model calls yet" and both =~ "tok"

    # Exactly wide enough: both; one less: the higher-priority tokens segment alone.
    assert StatusBar.line(usage, nil, nil, only, String.length(both)) == both
    narrow = StatusBar.line(usage, nil, nil, only, String.length(both) - 1)
    assert narrow =~ "tok" and not (narrow =~ "calls")
  end

  test "a newer key makes older blink timers stale" do
    state = state() |> Tui.wake_cursor() |> Tui.wake_cursor()
    stale = state.blink - 1
    assert {^state, []} = Tui.handle_info({:blink, stale}, state)
  end

  # --- a whole TUI state, against a fake daemon ------------------------------------------------

  # A stand-in for `Xeito.Client`: forwards each request to the test and answers ok. Not linked:
  # a request task may still be calling it when the test ends, so it stops itself once idle.
  defp fake_client do
    test = self()
    spawn(fn -> serve(test) end)
  end

  defp serve(test) do
    receive do
      {:"$gen_call", from, {:request, req}} ->
        send(test, {:request, req})
        GenServer.reply(from, %{"ok" => true})
        serve(test)
    after
      2_000 -> :ok
    end
  end

  defp tui(opts \\ []) do
    file = Path.join(System.tmp_dir!(), "xeito-tui-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(file) end)

    Tui.new(
      Keyword.merge(
        [client: fake_client(), session: "ses-t", cwd: "/w", size: {24, 80}, prefs: Config.load(file), prefs_file: file],
        opts
      )
    )
  end

  defp key(k, mods \\ []), do: %Event.Key{key: k, modifiers: mods}
  defp char(c), do: %Event.Key{key: c, char: c}
  defp typing(state, text), do: Enum.reduce(String.graphemes(text), state, &elem(Tui.update({:input, char(&1)}, &2), 0))
  defp submit(state, text), do: state |> typing(text) |> then(&Tui.update(:submit, &1))
  defp value(state), do: TextInput.get_value(state.input)

  describe "new/1" do
    test "an idle state with a greeting after the earlier turns, the bar from the preferences" do
      state = tui(earlier: ["> hi", "hello"])
      assert ["> hi", "hello", "session ses-t · /help" <> _] = state.lines
      assert %{leaf: "idle", bar: true, width: 80, height: 24, scroll: 0, hidden: []} = state
      refute tui(status_bar: false).bar
    end
  end

  describe "event_to_msg/2: keys become messages" do
    test "Ctrl-C and Ctrl-D quit, Ctrl-T toggles the status bar, other modifiers are ignored" do
      assert Tui.event_to_msg(key(:c, [:ctrl]), tui()) == {:msg, :quit}
      assert Tui.event_to_msg(key("d", [:ctrl]), tui()) == {:msg, :quit}
      assert Tui.event_to_msg(key(:t, [:ctrl]), tui()) == {:msg, :toggle_bar}
      assert Tui.event_to_msg(key(:c, [:alt]), tui()) == :ignore
    end

    test "Enter submits, Up and Down recall prompts, PgUp and PgDn scroll, a resize resizes, the rest is ignored" do
      assert Tui.event_to_msg(key(:enter), tui()) == {:msg, :submit}
      assert Tui.event_to_msg(key(:up), tui()) == {:msg, {:recall, :older}}
      assert Tui.event_to_msg(key(:down), tui()) == {:msg, {:recall, :newer}}
      assert Tui.event_to_msg(key(:page_up), tui()) == {:msg, {:scroll, 10}}
      assert Tui.event_to_msg(key(:page_down), tui()) == {:msg, {:scroll, -10}}
      assert Tui.event_to_msg(%Event.Resize{width: 100, height: 30}, tui()) == {:msg, {:resize, 100, 30}}
      assert Tui.event_to_msg(%Event.Focus{}, tui()) == :ignore
    end

    test "y and n are typed like any key, so a review can be answered in words" do
      waiting = %{tui() | waiting: true}
      assert Tui.event_to_msg(char("y"), waiting) == {:msg, {:input, char("y")}}
      assert Tui.event_to_msg(char("n"), waiting) == {:msg, {:input, char("n")}}
    end

    test "Esc halts" do
      assert Tui.event_to_msg(key(:escape), tui()) == {:msg, :halt}
    end
  end

  describe "update/2" do
    test "a typed prompt is sent to the session and echoed; the input clears" do
      {state, []} = submit(%{tui() | scroll: 5}, "fix it")
      assert_receive {:request, %{"cmd" => "prompt", "session" => "ses-t", "text" => "fix it"}}
      assert List.last(state.lines) == "> fix it"
      assert value(state) == "" and state.scroll == 0
    end

    test "an empty prompt steps a paused run, and does nothing otherwise" do
      {state, []} = Tui.update(:submit, %{tui() | paused: true})
      assert_receive {:request, %{"text" => "/next"}}
      refute state.paused

      plain = tui()
      {state, []} = Tui.update(:submit, plain)
      assert state.lines == plain.lines
      refute_receive {:request, %{"cmd" => "prompt"}}
    end

    test "/quit, /exit and :quit end the TUI" do
      quit = TermUI.Command.quit(:normal)
      assert {_, [^quit]} = Tui.update(:quit, tui())
      assert {_, [^quit]} = submit(tui(), "/quit")
      assert {_, [^quit]} = submit(tui(), "/exit")
    end

    test "a review answer approves or denies, and ends the wait" do
      {state, []} = Tui.update({:review, "y"}, %{tui() | waiting: true})
      assert_receive {:request, %{"cmd" => "approve", "session" => "ses-t"}}
      assert List.last(state.lines) == "  approved"
      refute state.waiting

      {state, []} = Tui.update({:review, "n"}, %{tui() | waiting: true})
      assert_receive {:request, %{"cmd" => "deny"}}
      assert List.last(state.lines) == "  denied"
    end

    test "Ctrl-T toggles the status bar and the daemon's monitor with it" do
      {state, []} = Tui.update(:toggle_bar, %{tui() | monitor: %{"gpu" => 1}})
      refute state.bar
      assert state.monitor == nil
      assert_receive {:request, %{"cmd" => "monitor", "on" => false}}
    end

    test "scrolling stops at the bottom; a resize sets the size and the input's width" do
      {state, []} = Tui.update({:scroll, 10}, tui())
      assert state.scroll == 10
      {state, []} = Tui.update({:scroll, -30}, state)
      assert state.scroll == 0

      {state, []} = Tui.update({:resize, 100, 30}, tui())
      assert {state.width, state.height, state.input.width} == {100, 30, 98}
    end

    test "an unknown message changes nothing but the cursor" do
      state = tui()
      {after_msg, []} = Tui.update(:nonsense, state)
      assert %{after_msg | blink: state.blink, blink_until: state.blink_until} == state
    end
  end

  describe "answering a review and halting" do
    defp waiting, do: %{tui() | waiting: true, leaf: "ask_human"}

    test "Enter on y or n approves or denies" do
      {state, []} = submit(waiting(), "y")
      assert_receive {:request, %{"cmd" => "approve", "session" => "ses-t"}}
      refute state.waiting
      assert value(state) == ""

      {_, []} = submit(waiting(), " n ")
      assert_receive {:request, %{"cmd" => "deny"}}
    end

    test "other text answers it in words: sent as the prompt, the wait ends" do
      {state, []} = submit(waiting(), "use mix test --failed")
      assert_receive {:request, %{"cmd" => "prompt", "text" => "use mix test --failed"}}
      refute state.waiting
      assert List.last(state.lines) == "  instead: use mix test --failed"
    end

    test "a slash command during a review is a command, not the answer" do
      {state, []} = submit(waiting(), "/why")
      assert_receive {:request, %{"cmd" => "prompt", "text" => "/why"}}
      assert state.waiting
      assert List.last(state.lines) == "> /why"
    end

    test "without a review, y is an ordinary prompt" do
      {_, []} = submit(tui(), "y")
      assert_receive {:request, %{"cmd" => "prompt", "text" => "y"}}
    end

    test "Esc halts a running turn, and does nothing when idle" do
      {_, []} = Tui.update(:halt, %{tui() | leaf: "executing"})
      assert_receive {:request, %{"cmd" => "prompt", "text" => "/halt"}}

      {_, []} = Tui.update(:halt, tui())
      {_, []} = Tui.update(:halt, %{tui() | leaf: "disconnected"})
      refute_receive {:request, _}
    end
  end

  describe "recalling earlier prompts with Up and Down" do
    # Submits a prompt and waits until it reaches the daemon.
    defp sent(state, text) do
      {state, []} = submit(state, text)
      assert_receive {:request, %{"cmd" => "prompt", "text" => ^text}}
      state
    end

    defp up(state), do: state |> then(&Tui.update({:recall, :older}, &1)) |> elem(0)
    defp down(state), do: state |> then(&Tui.update({:recall, :newer}, &1)) |> elem(0)
    defp left(state, n), do: Enum.reduce(1..n, state, fn _, st -> elem(Tui.update({:input, key(:left)}, st), 0) end)

    test "Up goes back through the prompts, newest first, and stops at the oldest; Down comes back to the draft" do
      state = tui() |> sent("oldest") |> sent("middle") |> sent("newest")
      assert value(state) == ""

      older = Enum.scan(1..4, state, fn _, st -> up(st) end)
      assert Enum.map(older, &value/1) == ["newest", "middle", "oldest", "oldest"]

      newer = Enum.scan(1..4, List.last(older), fn _, st -> down(st) end)
      assert Enum.map(newer, &value/1) == ["middle", "newest", "", ""]
    end

    test "a recalled prompt is edited at its end" do
      state = tui() |> sent("hello world") |> up()
      assert {value(state), state.input.cursor_col} == {"hello world", 11}
    end

    test "the line being typed comes back exactly, trailing space included" do
      state = tui() |> sent("previous") |> typing("current draft ")
      assert state |> up() |> value() == "previous"
      assert state |> up() |> down() |> value() == "current draft "
    end

    test "with no earlier prompts, Up and Down leave the line and the cursor alone" do
      typed = tui() |> typing("fix the ") |> left(3)
      for moved <- [up(typed), down(typed), typed |> up() |> down()], do: assert(moved.input == typed.input)
    end

    test "Down while typing, with nothing newer, leaves the line alone" do
      typed = tui() |> sent("old") |> typing("fix the ") |> left(3)
      assert down(typed).input == typed.input
    end

    test "every non-empty line is remembered once in a row, local commands included" do
      state = tui() |> sent("a") |> sent("b") |> sent("b")
      {state, []} = Tui.update(:submit, state)
      {state, []} = submit(state, "/statusbar off")
      assert_receive {:request, %{"cmd" => "monitor"}}

      assert state |> up() |> value() == "/statusbar off"
      assert state |> up() |> up() |> value() == "b"
      assert state |> up() |> up() |> up() |> value() == "a"
    end

    test "a recalled prompt sent again becomes the newest" do
      state = tui() |> sent("a") |> sent("b") |> up() |> up()
      {state, []} = Tui.update(:submit, state)
      assert_receive {:request, %{"cmd" => "prompt", "text" => "a"}}
      assert state |> up() |> value() == "a"
      assert state |> up() |> up() |> value() == "b"
    end
  end

  describe "/statusbar" do
    defp statusbar(state \\ tui(), args) do
      {state, []} = submit(state, String.trim("/statusbar " <> args))
      state
    end

    defp saved(state), do: Config.load(state.prefs_file)["status_bar"]

    test "on, off, a bare toggle and reset are saved in the preferences" do
      off = statusbar("off")
      assert {off.bar, saved(off)["visible"]} == {false, false}
      assert value(off) == ""
      assert statusbar(off, "on").bar
      assert statusbar(off, "").bar
      refute statusbar("").bar

      reset = statusbar(%{off | hidden: ["cpu"]}, "reset")
      assert {reset.bar, reset.hidden, saved(reset)} == {true, [], %{"visible" => true, "hidden" => []}}
    end

    test "show and hide take known segments, separated by spaces or commas" do
      hidden = statusbar("hide cpu,queue")
      assert hidden.hidden == ["cpu", "queue"] and saved(hidden)["hidden"] == ["cpu", "queue"]
      assert statusbar(hidden, "hide cpu").hidden == ["cpu", "queue"]
      assert statusbar(hidden, "show queue").hidden == ["cpu"]

      unknown = statusbar("hide cpu nope")
      assert unknown.hidden == []
      assert List.last(unknown.lines) =~ "✗ unknown segment nope"
    end

    test "segments lists them, marking the hidden ones; anything else shows the usage" do
      listed = "segments" |> statusbar() |> then(&statusbar(%{&1 | hidden: ["cpu"]}, "segments"))
      assert List.last(listed.lines) =~ ~r/^status bar on · segments: .*·cpu/
      assert List.last(statusbar("sideways").lines) =~ "/statusbar [on|off|reset|segments]"
    end

    test "a preference that cannot be saved still applies, for this session" do
      state = statusbar(%{tui() | prefs_file: "/dev/null/xeito/tui.json"}, "off")
      refute state.bar
      assert List.last(state.lines) =~ "✗ could not save preferences"
    end
  end

  describe "handle_info/2: daemon events and replies" do
    test "a monitor tick stores the snapshot and refreshes a stale workspace" do
      {state, []} = Tui.handle_info({:xeito_event, %{"event" => "monitor", "attrs" => %{"cpu" => 3}}}, tui())
      assert state.monitor == %{"cpu" => 3}
      assert_receive {:request, %{"cmd" => "workspace", "session" => "ses-t"}}

      {_, []} = Tui.handle_info({:xeito_event, %{"event" => "monitor", "attrs" => %{}}}, state)
      refute_receive {:request, %{"cmd" => "workspace"}}
    end

    test "a workspace event is stored; a failed reply is shown; anything else is ignored" do
      {state, []} = Tui.handle_info({:xeito_event, %{"event" => "workspace", "attrs" => %{"git" => "main"}}}, tui())
      assert state.workspace == %{"git" => "main"} and is_integer(state.workspace_at)

      {state, []} = Tui.handle_info({:xeito_reply, %{"ok" => false, "error" => "no such session"}}, tui())
      assert List.last(state.lines) == "✗ no such session"

      plain = tui()
      assert Tui.handle_info({:xeito_reply, %{"ok" => true}}, plain) == {plain, []}
    end

    test "other daemon events go to the transcript" do
      event = %{"event" => "turn_finished", "run" => "ses-t/t1", "attrs" => %{}}
      {state, []} = Tui.handle_info({:xeito_event, event}, %{tui() | leaf: "thinking", waiting: true})
      assert %{leaf: "idle", waiting: false} = state
    end
  end

  describe "apply_event/2 tracks the run for the status line" do
    defp event(type, attrs, run \\ "ses-t/t1"), do: %{"event" => type, "run" => run, "attrs" => attrs}

    test "a run's machine, states, decisions and spend" do
      state =
        tui()
        |> Tui.apply_event(event("run_selected", %{"machine" => "Elixir.Xeito.Machines.Chat"}))
        |> Tui.apply_event(event("state_entered", %{"state" => "thinking"}))
        |> Tui.apply_event(event("state_entered", %{"state" => "classify"}, "ses-t/t1/intent"))
        |> Tui.apply_event(event("decision_made", %{"decision_type" => "X", "actor" => "large", "usd" => 0.25}))
        |> Tui.apply_event(event("decision_made", %{"decision_type" => "X", "actor" => "small"}))

      assert %{machine: "Chat", leaf: "thinking", decisions: 2, tier: "small", usd: 0.25} = state
      assert is_integer(state.started)
      assert Tui.status_line(state) =~ ~r/^ state thinking · \d+\.\d s · tier small · 2 decisions · \$0\.25$/
    end

    test "intent, a review, a pause, the end of a turn and a lost daemon" do
      state = Tui.apply_event(tui(), event("intent", %{"actor" => "rule"}))
      assert %{leaf: "intent", decisions: 1, tier: "rule"} = state

      waiting = Tui.apply_event(state, event("human_needed", %{}))
      assert Tui.status_line(waiting) =~ "review: y / n"
      paused = Tui.apply_event(state, event("paused", %{}))
      assert Tui.status_line(%{paused | scroll: 3}) =~ "paused: Enter steps · scrolled"

      done = Tui.apply_event(%{waiting | paused: true}, event("turn_finished", %{}))
      assert %{leaf: "idle", waiting: false, paused: false, started: nil} = done
      assert Tui.status_line(done) == " state idle · tier rule · 1 decisions"
      assert Tui.apply_event(done, event("disconnected", %{})).leaf == "disconnected"
    end
  end

  describe "view/1: the screen" do
    # The rows a view draws, top to bottom: text for a line, :row for one of several nodes side by side.
    defp screen(%RenderNode{type: :stack, direction: :vertical, children: children}),
      do: Enum.flat_map(children, &screen/1)

    defp screen(%RenderNode{type: :text, content: content}), do: [content]
    defp screen(_horizontal), do: [:row]

    defp border?(row), do: is_binary(row) and row != "" and String.trim(row, "─") == ""

    test "the prompt line sits between two full-width, dim border lines" do
      state = tui()
      rows = screen(Tui.view(state))
      i = Enum.find_index(rows, &border?/1)

      assert [border, :row, border] = Enum.slice(rows, i, 3)
      assert border == String.duplicate("─", state.width)
      borders = for %RenderNode{type: :text, content: ^border} = node <- Tui.view(state).children, do: node.style.attrs
      assert borders == [MapSet.new([:dim]), MapSet.new([:dim])]
    end

    test "the screen fills the terminal exactly, with or without the status bar" do
      for bar <- [false, true], height <- [24, 10] do
        state = %{tui(status_bar: bar) | height: height}
        assert length(screen(Tui.view(state))) == height, "status bar #{bar}, #{height} rows"
      end
    end

    test "long lines wrap at the screen's width; a marked line's continuation is indented past its gutter" do
      state = %{
        tui(status_bar: false)
        | width: 12,
          lines: [{:marked, :red, "⁹", "$ rm -rf one two three"}, "", "abcdefghijklmnopq"]
      }

      rows = state |> Tui.view() |> screen()

      # The dot, its superscript and a space take 3 columns; the text wraps in the other 9.
      assert [_header, :row, "   one two t", "   hree", "", "abcdefghijkl", "mnopq" | _] = rows
    end

    test "the status line stays at the bottom, below the border, and shows a pending review" do
      rows = %{tui(status_bar: false) | waiting: true} |> Tui.view() |> screen()
      assert border?(Enum.at(rows, -2))
      assert List.last(rows) =~ ~r/^ state idle .* review: y \/ n/
    end
  end

  describe "init/1: a session from the daemon" do
    # A daemon that answers start, attach and history; `history` is what it reports as earlier turns.
    defp daemon(history) do
      dir = Path.join(System.tmp_dir!(), "xeito-tuid-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      socket = Path.join(dir, "d.sock")
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket}, packet: :line, active: false])
      server = spawn(fn -> accept(listen, history) end)
      on_exit(fn -> Process.exit(server, :kill) && File.rm_rf(dir) end)
      socket
    end

    defp accept(listen, history) do
      {:ok, conn} = :gen_tcp.accept(listen)
      answer(conn, history)
    end

    defp answer(conn, history) do
      with {:ok, line} <- :gen_tcp.recv(conn, 0) do
        req = JSON.decode!(line)
        :ok = :gen_tcp.send(conn, [JSON.encode!(Map.put(reply(req, history), "id", req["id"])), "\n"])
        answer(conn, history)
      end
    end

    defp reply(%{"cmd" => "start"}, _), do: %{ok: true, session: "ses-new", status: %{cwd: "/from/daemon"}}
    defp reply(%{"cmd" => "attach", "session" => "ses-gone"}, _), do: %{ok: false, error: "no such session"}
    defp reply(%{"cmd" => "attach", "session" => id}, _), do: %{ok: true, session: id, status: %{cwd: "/w"}}
    defp reply(%{"cmd" => "history"}, :broken), do: %{ok: false, error: "no history"}
    defp reply(%{"cmd" => "history"}, history), do: %{ok: true, history: history}
    defp reply(_req, _), do: %{ok: true}

    defp init_with(env) do
      previous = Application.get_env(:xeito, :tui)
      Application.put_env(:xeito, :tui, env)

      on_exit(fn ->
        if previous, do: Application.put_env(:xeito, :tui, previous), else: Application.delete_env(:xeito, :tui)
      end)

      Tui.init([])
    end

    test "a new session: started in the daemon, in the workspace it reports" do
      state = init_with(socket: daemon([]), cwd: "/given")
      assert %{session: "ses-new", cwd: "/from/daemon", lines: ["session ses-new · /help" <> _]} = state
    end

    test "attaching shows the earlier turns: prompts and the first line of each answer" do
      history = [
        %{role: "user", content: "fix the test"},
        %{role: "assistant", content: "Fixed.\nDetails follow."},
        %{role: "tool", content: "output"},
        %{role: "assistant", content: ""}
      ]

      state = init_with(socket: daemon(history), cwd: "/w", session: "ses-old")
      assert ["> fix the test", "Fixed.", "session ses-old" <> _] = state.lines
    end

    test "attaching without a history shows none; a session that cannot be opened is an error" do
      assert ["session ses-old" <> _] = init_with(socket: daemon(:broken), cwd: "/w", session: "ses-old").lines

      assert_raise RuntimeError, "could not open a session: no such session", fn ->
        init_with(socket: daemon([]), session: "ses-gone")
      end
    end
  end

  describe "Tab completes commands, machine names and skill names" do
    defp tab(state), do: :complete |> Tui.update(state) |> elem(0)

    test "Tab is the completion key" do
      assert Tui.event_to_msg(key(:tab), tui()) == {:msg, :complete}
    end

    test "one match completes the command, whatever the case typed" do
      assert tui() |> typing("/he") |> tab() |> value() == "/help"
      assert tui() |> typing("/sta") |> tab() |> value() == "/statusbar"
      assert tui() |> typing("/HAL") |> tab() |> value() == "/halt"
    end

    test "several matches: each Tab shows the next, in order, and wraps around" do
      tabbed = tui() |> typing("/s") |> Stream.iterate(&tab/1) |> Enum.take(5) |> Enum.map(&value/1)
      assert tabbed == ["/s", "/skill:", "/statusbar", "/step", "/skill:"]
    end

    test "typing after a Tab completes from the new text" do
      # "/skill:x" names no skill, so the line stays; it does not cycle on to "/statusbar".
      assert tui() |> typing("/s") |> tab() |> typing("x") |> tab() |> value() == "/skill:x"
    end

    test "no match, or a line that is not a command, stays as it is" do
      assert tui() |> typing("/zz") |> tab() |> value() == "/zz"
      assert tui() |> typing("hello") |> tab() |> value() == "hello"
      assert tui() |> tab() |> value() == ""
    end

    test "after /machine, a machine name" do
      assert tui() |> typing("/machine fix") |> tab() |> value() == "/machine fix_failing_test"
      assert tui() |> typing("/machine c") |> tab() |> tab() |> value() == "/machine check"
    end

    @tag :tmp_dir
    test "after /skill:, a skill of the workspace", %{tmp_dir: dir} do
      skill = Path.join(dir, ".agents/skills/zz-tui-skill")
      File.mkdir_p!(skill)
      File.write!(Path.join(skill, "SKILL.md"), "---\nname: zz-tui-skill\ndescription: a test skill\n---\nbody\n")

      assert [cwd: dir] |> tui() |> typing("/skill:zz-tui") |> tab() |> value() == "/skill:zz-tui-skill"
    end

    test "the commands are the daemon's and the TUI's own" do
      assert Tui.commands() == Enum.sort(~w(quit exit statusbar) ++ Xeito.Session.commands())
    end
  end
end
