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
        "actor" => "local",
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

  describe "banner/1: the greeting above the session line" do
    test "keys, example prompts, the workspace's instructions and skills" do
      lines = Tui.banner("/w")

      assert lines == [
               "Enter sends · Esc halts · Up/Down recall · Tab completes · Ctrl-J steers · Ctrl-T status bar · /help",
               "try: fix the failing test · run the checks · commit these changes · explain this code",
               "machines: chat · check · commit · fix_failing_test · run_tests",
               "no AGENTS.md in /w",
               "no skills in /w",
               ""
             ]
    end

    @tag :tmp_dir
    test "the first lines of AGENTS.md, the workspace's skills by name, and how many of yours", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "# Notes\n\nline two\n\nline three\nline four\n")

      for {root, name} <- [
            {".agents/skills", "zz-tui-skill"},
            {"home/.agents/skills", "mine-a"},
            {"home/.agents/skills", "mine-b"}
          ] do
        skill = Path.join([dir, root, name])
        File.mkdir_p!(skill)
        File.write!(Path.join(skill, "SKILL.md"), "---\nname: #{name}\ndescription: a long description\n---\nbody\n")
      end

      assert Enum.drop(Tui.banner(dir, home: Path.join(dir, "home")), 3) == [
               "AGENTS.md: # Notes",
               "  line two",
               "  line three",
               "  … (#{Path.join(dir, "AGENTS.md")})",
               "skills here: /skill:zz-tui-skill · and 2 of yours (/skill: then Tab)",
               ""
             ]
    end

    @tag :tmp_dir
    test "only your own skills, or no directory at all", %{tmp_dir: dir} do
      skill = Path.join(dir, "home/.agents/skills/mine")
      File.mkdir_p!(skill)
      File.write!(Path.join(skill, "SKILL.md"), "---\nname: mine\ndescription: d\n---\n")

      File.write!(Path.join(dir, "AGENTS.md"), "\n  \n")
      lines = Tui.banner(dir, home: Path.join(dir, "home"))
      assert "no skills here · 1 of yours (/skill: then Tab)" in lines
      assert "AGENTS.md is empty (#{Path.join(dir, "AGENTS.md")})" in lines
      assert Enum.drop(Tui.banner(nil), 3) == ["no AGENTS.md", "no skills", ""]
    end
  end

  describe "new/1" do
    test "an idle state with a greeting after the earlier turns, the bar from the preferences" do
      state = tui(earlier: ["> hi", "hello"])
      assert ["> hi", "hello" | banner] = state.lines
      [header | _] = Enum.reverse(banner)
      assert banner == Tui.banner("/w") ++ [header]
      assert header =~ "session ses-t · /help"
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

  describe "lines typed while a turn runs: queued in the session" do
    defp qevent(type, attrs), do: %{"event" => type, "attrs" => attrs}
    defp queue_rows(state), do: state |> Tui.view() |> screen() |> Enum.filter(&(is_binary(&1) and &1 =~ "⏸"))

    test "a queued line shows above the prompt until it is sent; the screen still fits" do
      state =
        [status_bar: false]
        |> tui()
        |> Tui.apply_event(qevent("queued", %{"text" => "/run mix test", "queued" => 1}))
        |> Tui.apply_event(qevent("queued", %{"text" => "and commit", "queued" => 2}))

      assert state.queue == ["/run mix test", "and commit"]

      assert queue_rows(state) ==
               Enum.map([" ⏸ queued: /run mix test", " ⏸ queued: and commit"], &String.pad_trailing(&1, 80))

      assert length(screen(Tui.view(state))) == state.height

      sent = Tui.apply_event(state, qevent("dequeued", %{"text" => "/run mix test", "outcome" => "sent"}))
      assert sent.queue == ["and commit"]
    end

    test "a held queue says how to send or drop it, and the keys do that" do
      state =
        [status_bar: false]
        |> tui()
        |> Tui.apply_event(qevent("queued", %{"text" => "and commit", "queued" => 1}))
        |> Tui.apply_event(qevent("queue_held", %{"reason" => "halted", "queued" => 1}))

      assert [row] = queue_rows(state)
      assert String.trim_trailing(row) == " ⏸ held (the turn halted): and commit · Enter sends · Esc drops"

      {_, []} = Tui.update(:submit, state)
      assert_receive {:request, %{"cmd" => "prompt", "text" => "/send"}}

      {_, []} = Tui.update(:halt, state)
      assert_receive {:request, %{"cmd" => "prompt", "text" => "/drop"}}

      dropped = Tui.apply_event(state, qevent("dequeued", %{"text" => "and commit", "outcome" => "dropped"}))
      assert {dropped.queue, dropped.held} == {[], false}
      assert queue_rows(dropped) == []
    end

    test "Enter on an empty line does nothing, and Esc halts, when the queue is not held" do
      state = Tui.apply_event(%{tui() | leaf: "executing"}, qevent("queued", %{"text" => "next", "queued" => 1}))
      {_, []} = Tui.update(:submit, state)
      refute_receive {:request, %{"text" => "/send"}}, 100

      {_, []} = Tui.update(:halt, state)
      assert_receive {:request, %{"cmd" => "prompt", "text" => "/halt"}}
    end
  end

  describe "steering with Ctrl-J: a line for the running chat turn" do
    test "Ctrl-J is the steering key" do
      assert Tui.event_to_msg(key("j", [:ctrl]), tui()) == {:msg, :steer}
    end

    test "Ctrl-J sends the typed line as /steer, clears the prompt and remembers the line" do
      state = typing(%{tui() | leaf: "thinking"}, "use pytest")
      {steered, []} = Tui.update(:steer, state)

      assert_receive {:request, %{"cmd" => "prompt", "text" => "/steer use pytest"}}
      assert value(steered) == ""
      assert hd(steered.prompt_history) == "use pytest"
    end

    test "on an empty line, Ctrl-J does nothing" do
      {_, []} = Tui.update(:steer, tui())
      refute_receive {:request, _}, 100
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

  defp write_skills(dir, skills) do
    for {name, description} <- skills do
      skill = Path.join(dir, ".agents/skills/#{name}")
      File.mkdir_p!(skill)
      File.write!(Path.join(skill, "SKILL.md"), "---\nname: #{name}\ndescription: #{description}\n---\nbody\n")
    end
  end

  describe "/skills: finding a skill by what it does" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      write_skills(dir, [
        {"youtube-transcript", "Fetch transcripts from YouTube videos for summarization and analysis."},
        {"code-review", "Review the changes since a fixed point along two axes: standards and spec."},
        {"brave-search", String.duplicate("Web search and content extraction. ", 5)}
      ])

      :ok
    end

    test "/skills <words> lists the skills they match, the best first, with what each does", %{tmp_dir: dir} do
      {state, []} = submit(tui(cwd: dir), "/skills summarise a talk")

      assert Enum.take(state.lines, -2) == [
               ~s(skills for "summarise a talk", the best first:),
               "  /skill:youtube-transcript · Fetch transcripts from YouTube videos for summarization and analysis."
             ]

      assert value(state) == ""
    end

    test "/skills alone lists them all, a long description cut", %{tmp_dir: dir} do
      {state, []} = submit(tui(cwd: dir), "/skills")
      [heading, brave, review, youtube] = Enum.take(state.lines, -4)

      assert heading == "3 skills (/skills <words> finds one by what it does):"

      assert brave ==
               "  /skill:brave-search · " <>
                 String.slice(String.duplicate("Web search and content extraction. ", 5), 0, 99) <> "…"

      assert review =~ "  /skill:code-review · Review the changes"
      assert youtube =~ "  /skill:youtube-transcript · "
    end

    test "says so when nothing matches", %{tmp_dir: dir} do
      {state, []} = submit(tui(cwd: dir), "/skills zzz")
      assert List.last(state.lines) == ~s(no skill matches "zzz" · /skills alone lists them all)
    end
  end

  describe "/legend: what the risk dots mean" do
    test "each dot in its own colour, the same as on commands, and what the small number is" do
      {state, []} = submit(tui(), "/legend")
      legend = Enum.take(state.lines, -7)

      assert legend == [
               "Risk: the dot beside each command",
               {:marked, :green, "", "safe · runs without asking"},
               {:marked, :yellow, "", "review · waits for you: y, n, or say what to do instead"},
               {:marked, :yellow, "", "abstain · no decider was sure: waits for you too"},
               {:marked, :red, "", "forbidden · refused, never runs"},
               {:marked, :green, "⁹⁴", "the small number · how sure the decider was, in percent"},
               ""
             ]

      assert value(state) == ""
    end

    test "the legend's colours are the dots' colours" do
      for {value, color} <- [{"safe", :green}, {"review", :yellow}, {"abstain", :yellow}, {"forbidden", :red}] do
        state =
          Tui.apply_event(tui(), %{
            "event" => "decision_made",
            "attrs" => %{"decision_type" => "Xeito.Decisions.Risk", "value" => value, "confidence" => 0.5}
          })

        assert {^color, "⁵⁰"} = state.marker
        {legend, []} = submit(tui(), "/legend")
        assert Enum.any?(legend.lines, &match?({:marked, ^color, "", ^value <> " ·" <> _}, &1))
      end
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
        |> Tui.apply_event(event("decision_made", %{"decision_type" => "X", "actor" => "local", "usd" => 0.25}))
        |> Tui.apply_event(event("decision_made", %{"decision_type" => "X", "actor" => "local_decision"}))

      assert %{machine: "Chat", leaf: "thinking", decisions: 2, tier: "local_decision", usd: 0.25} = state
      assert is_integer(state.started)

      assert Tui.status_line(state, 80) =~
               ~r/^ ⠋ state thinking · \d+\.\d s · tier local_decision · 2 decisions · \$0\.25 +\/w $/
    end

    test "intent, a review, a pause, the end of a turn and a lost daemon" do
      state = Tui.apply_event(tui(), event("intent", %{"actor" => "rule"}))
      assert %{leaf: "intent", decisions: 1, tier: "rule"} = state

      waiting = Tui.apply_event(state, event("human_needed", %{}))
      assert Tui.status_line(waiting, 80) =~ "review: y / n"
      paused = Tui.apply_event(state, event("paused", %{}))
      assert Tui.status_line(%{paused | scroll: 3}, 80) =~ "paused: Enter steps · scrolled"

      done = Tui.apply_event(%{waiting | paused: true}, event("turn_finished", %{}))
      assert %{leaf: "idle", waiting: false, paused: false, started: nil} = done
      assert Tui.status_line(done, 80) =~ ~r/^ ○ state idle · tier rule · 1 decisions +\/w $/
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
      assert List.last(rows) =~ ~r/^ ◆ state idle .* review: y \/ n/
    end

    test "the header names the machine; where commands run is in the status line" do
      [header | _] = %{tui(status_bar: false) | machine: "Chat"} |> Tui.view() |> screen()
      assert String.trim_trailing(header) == " xeito · Chat"
    end
  end

  describe "the status line: a working marker, and where commands run" do
    defp marker(state), do: state |> Tui.status_line(80) |> String.slice(1, 1)
    defp working(state \\ tui()), do: Tui.apply_event(state, event("state_entered", %{"state" => "thinking"}))

    test "idle is a still circle, waiting for you a still diamond, a lost daemon a cross" do
      assert marker(tui()) == "○"
      assert marker(Tui.apply_event(working(), event("human_needed", %{}))) == "◆"
      assert marker(Tui.apply_event(working(), event("paused", %{}))) == "◆"
      assert marker(Tui.apply_event(tui(), event("disconnected", %{}))) == "✗"
    end

    test "working is a spinner: each tick of its timer shows the next frame, around and around" do
      state = working()
      assert marker(state) == "⠋"

      frames =
        state
        |> Stream.iterate(fn s -> s |> then(&Tui.handle_info({:spin, &1.spin_gen}, &1)) |> elem(0) end)
        |> Enum.take(11)
        |> Enum.map(&marker/1)

      assert frames == ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏ ⠋)
    end

    test "the timer starts when work starts and stops when it stops, so an idle TUI sleeps" do
      {state, []} = Tui.handle_info({:xeito_event, event("state_entered", %{"state" => "thinking"})}, tui())
      assert_receive {:spin, gen}, 500

      # More events while working start no second timer.
      {state, []} = Tui.handle_info({:xeito_event, event("state_entered", %{"state" => "executing"})}, state)
      refute_receive {:spin, _}, 300

      {state, []} = Tui.handle_info({:spin, gen}, state)
      assert_receive {:spin, ^gen}, 500

      {done, []} = Tui.handle_info({:xeito_event, event("turn_finished", %{})}, state)
      {done, []} = Tui.handle_info({:spin, gen}, done)
      refute_receive {:spin, _}, 300
      assert marker(done) == "○"

      # Waiting for you stops it too; a stale tick changes nothing.
      {waiting, []} = Tui.handle_info({:xeito_event, event("human_needed", %{})}, working())
      assert {:spin, waiting.spin_gen} |> Tui.handle_info(waiting) |> elem(0) |> marker() == "◆"
      assert Tui.handle_info({:spin, -1}, state) == {state, []}
    end

    test "the workspace, shortened from the left, and its git branch, at the right end" do
      home = System.user_home!()
      state = %{tui(cwd: Path.join(home, "Development/xeito")) | workspace: %{"git" => %{"branch" => "main"}}}
      line = Tui.status_line(state, 80)
      assert String.length(line) == 80
      assert String.ends_with?(line, " ~/Development/xeito (main) ")

      deep = %{tui(cwd: "/very/long/path/with/many/levels/and/a/project") | workspace: %{"git" => nil}}
      assert String.ends_with?(Tui.status_line(deep, 80), " …/many/levels/and/a/project ")
    end

    test "on a narrow screen the state gives way, the workspace stays" do
      state = %{tui(cwd: "/srv/app") | workspace: %{"git" => %{"branch" => "dev"}}}
      line = Tui.status_line(state, 30)
      assert line == " ○ state idle… /srv/app (dev) "
      assert String.length(line) == 30
    end
  end

  describe "init/1: a session from the daemon" do
    # A daemon that answers open, start, attach, history and prompts; `history` is what it reports
    # as earlier turns, and `continued` whether `open` found a session to continue.
    defp daemon(history, continued \\ false) do
      dir = Path.join(System.tmp_dir!(), "xeito-tuid-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      socket = Path.join(dir, "d.sock")
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket}, packet: :line, active: false])
      server = spawn(fn -> accept(listen, {history, continued}) end)
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

    defp reply(%{"cmd" => "open"}, {_, false}),
      do: %{ok: true, session: "ses-new", status: %{cwd: "/from/daemon"}, continued: false}

    defp reply(%{"cmd" => "open"}, {_, true}), do: %{ok: true, session: "ses-last", status: %{cwd: "/w"}, continued: true}
    defp reply(%{"cmd" => "attach", "session" => "ses-gone"}, _), do: %{ok: false, error: "no such session"}
    defp reply(%{"cmd" => "attach", "session" => id}, _), do: %{ok: true, session: id, status: %{cwd: "/w"}}
    defp reply(%{"cmd" => "transcript"}, {:broken, _}), do: %{ok: false, error: "no transcript"}
    defp reply(%{"cmd" => "transcript"}, {turns, _}), do: %{ok: true, turns: turns}
    defp reply(%{"cmd" => "prompts"}, _), do: %{ok: true, prompts: ["/why", "fix the test"]}
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
      assert %{session: "ses-new", cwd: "/from/daemon", lines: lines} = state
      [header | banner] = Enum.reverse(lines)
      assert Enum.reverse(banner) == Tui.banner("/from/daemon")
      assert header =~ "session ses-new · /help"
    end

    test "a directory's last updated session is continued, with its earlier turns" do
      turns = [%{prompt: "fix the test", answer: "Fixed."}]
      state = init_with(socket: daemon(turns, true), cwd: "/w")

      assert %{session: "ses-last", lines: ["> fix the test", "Fixed." | banner]} = state
      [header | _] = Enum.reverse(banner)
      assert banner == Tui.banner("/w") ++ [header]
      assert header =~ "continuing session ses-last · /sessions"
    end

    test "Up and Down start with the prompts typed in this directory before" do
      state = init_with(socket: daemon([]), cwd: "/w")
      assert state.prompt_history == ["/why", "fix the test"]
    end

    test "attaching shows the earlier turns: each prompt, the first line of earlier answers, the last in full" do
      turns = [
        %{prompt: "fix the test\nwith care", answer: "Fixed.\nDetails follow."},
        %{prompt: "/run mix test", answer: nil},
        %{prompt: "and now?", answer: "All green.\n\n- 12 tests\n- 0 failures"}
      ]

      state = init_with(socket: daemon(turns), cwd: "/w", session: "ses-old")

      assert [
               "> fix the test",
               "Fixed.",
               "> /run mix test",
               "> and now?",
               "All green.",
               "",
               "- 12 tests",
               "- 0 failures" | banner
             ] = state.lines

      [header | _] = Enum.reverse(banner)
      assert banner == Tui.banner("/w") ++ [header]
      assert header =~ "session ses-old"
    end

    test "attaching without a history shows none; a session that cannot be opened is an error" do
      state = init_with(socket: daemon(:broken), cwd: "/w", session: "ses-old")
      [header | _] = Enum.reverse(state.lines)
      assert state.lines == Tui.banner("/w") ++ [header]
      assert header =~ "session ses-old"

      assert_raise RuntimeError, "could not open a session: no such session", fn ->
        init_with(socket: daemon([]), session: "ses-gone")
      end
    end
  end

  describe "/sessions: this directory's sessions, to switch to or start another" do
    defp listed(state) do
      sessions = [
        %{
          "id" => "ses-t",
          "last" => "2026-10-03T20:16:26Z",
          "prompts" => 5,
          "last_prompt" => "WRITE! NOW!",
          "live" => true
        },
        %{"id" => "ses-a", "last" => "2026-10-02T09:00:00Z", "prompts" => 1, "last_prompt" => nil, "live" => false}
      ]

      {state, []} = Tui.handle_info({:xeito_reply, :sessions, %{"ok" => true, "sessions" => sessions}}, state)
      state
    end

    test "/sessions asks the daemon for this directory's sessions and lists them, numbered" do
      {state, []} = submit(tui(), "/sessions")
      assert_receive {:request, %{"cmd" => "sessions", "cwd" => "/w"}}
      state = listed(state)

      assert Enum.any?(state.lines, &(&1 =~ ~r/^  1  ses-t · .* · 5 prompts · > WRITE! NOW!  \(this one\)$/))
      assert Enum.any?(state.lines, &(&1 =~ ~r/^  2  ses-a · .* · 1 prompt$/))
      assert List.last(state.lines) =~ "/sessions N switches to one · /sessions new starts another"
      assert state.listed == ["ses-t", "ses-a"]
    end

    test "/sessions N switches to a listed session and shows its earlier turns" do
      state = listed(tui())
      {state, []} = submit(state, "/sessions 2")
      assert_receive {:request, %{"cmd" => "attach", "session" => "ses-a", "cwd" => "/w"}}

      {state, []} = Tui.handle_info({:xeito_reply, :switched, %{"ok" => true, "session" => "ses-a"}}, state)
      assert %{session: "ses-a", leaf: "idle", queue: []} = state
      assert ["session ses-a · /help" <> _] = state.lines
      assert_receive {:request, %{"cmd" => "transcript", "session" => "ses-a", "cwd" => "/w"}}

      transcript = %{"ok" => true, "turns" => [%{"prompt" => "earlier", "answer" => "Done."}]}
      {state, []} = Tui.handle_info({:xeito_reply, {:earlier, "ses-a"}, transcript}, state)
      assert ["> earlier", "Done.", "session ses-a · /help" <> _] = state.lines
    end

    test "/sessions new starts another session in this directory" do
      {state, []} = submit(tui(), "/sessions new")
      assert_receive {:request, %{"cmd" => "start", "cwd" => "/w"}}
      {state, []} = Tui.handle_info({:xeito_reply, :switched, %{"ok" => true, "session" => "ses-n"}}, state)
      assert %{session: "ses-n", lines: ["session ses-n · /help" <> _]} = state
    end

    test "a number that was not listed, or a failed switch, says so and changes nothing" do
      {state, []} = submit(listed(tui()), "/sessions 7")
      assert List.last(state.lines) =~ "no session 7: /sessions lists them"
      refute_received {:request, %{"cmd" => "attach"}}

      {state, []} = Tui.handle_info({:xeito_reply, :switched, %{"ok" => false, "error" => "no such session"}}, state)
      assert state.session == "ses-t"
      assert List.last(state.lines) =~ "✗ no such session"
    end

    test "after a switch, events of the other session are not shown" do
      state = tui()
      other = %{"event" => "notice", "session" => "ses-other", "attrs" => %{"text" => "elsewhere"}}
      assert {^state, []} = Tui.handle_info({:xeito_event, other}, state)

      mine = %{"event" => "notice", "session" => "ses-t", "attrs" => %{"text" => "here"}}
      {state, []} = Tui.handle_info({:xeito_event, mine}, state)
      assert Enum.any?(state.lines, &(&1 =~ "here"))
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
      tabbed = tui() |> typing("/s") |> Stream.iterate(&tab/1) |> Enum.take(9) |> Enum.map(&value/1)
      assert tabbed == ["/s", "/send", "/sessions", "/skill:", "/skills", "/statusbar", "/steer", "/step", "/send"]
    end

    test "typing after a Tab completes from the new text" do
      # "/skill:x" names no skill, so the line stays; it does not cycle on to "/statusbar".
      assert tui() |> typing("/sk") |> tab() |> typing("x") |> tab() |> value() == "/skill:x"
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

    @tag :tmp_dir
    test "after /skill:, words that start no name find skills by what they do, after those they start",
         %{tmp_dir: dir} do
      write_skills(dir, [
        {"zz-video", "Fetch transcripts from YouTube videos."},
        {"zz-search", "Search the web and extract pages, and videos."},
        {"videos-cut", "Cut video files."}
      ])

      assert [cwd: dir] |> tui() |> typing("/skill:transcripts") |> tab() |> value() == "/skill:zz-video"

      tabbed =
        [cwd: dir] |> tui() |> typing("/skill:videos") |> Stream.iterate(&tab/1) |> Enum.take(4) |> Enum.map(&value/1)

      assert tabbed == ["/skill:videos", "/skill:videos-cut", "/skill:zz-video", "/skill:zz-search"]
    end

    test "the commands are the daemon's and the TUI's own" do
      assert Tui.commands() == Enum.sort(~w(quit exit statusbar legend sessions skills) ++ Xeito.Session.commands())
    end
  end
end
