defmodule Xeito.HarnessTest do
  # Chat calls happen in supervised effect tasks, so Req.Test stubs are shared (serial).
  use Xeito.Case, async: false

  alias Xeito.{Client, Effect, Log, Run, RunSupervisor, Session}
  alias Xeito.Client.Render
  alias Xeito.Decisions.{Risk, Triage}
  alias Xeito.Effects.Local
  alias Xeito.Machines.{Chat, FixFailingTest, RunTests}
  alias Xeito.Session.Router

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    %{ws: ws}
  end

  # --- a scripted Ollama: chat turns in order, decisions by value --------------------------

  # `turns` is a list of `{content, tool_calls}`; `decisions` maps a decision name to a value.
  defp ollama(test_pid, turns, decisions \\ %{}) do
    {:ok, script} = Agent.start_link(fn -> turns end)

    Req.Test.stub(:harness_ollama, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      req = if raw == "", do: %{}, else: JSON.decode!(raw)

      respond(conn, req, test_pid, script, decisions)
    end)

    [url: "http://ollama.test", plug: {Req.Test, :harness_ollama}, model: "big"]
  end

  defp respond(%{request_path: "/api/ps"} = conn, _req, _pid, _script, _decisions),
    do: Req.Test.json(conn, %{"models" => [%{"name" => "big", "model" => "big"}]})

  defp respond(conn, %{"format" => _} = req, test_pid, _script, decisions) do
    send(test_pid, {:decision_request, req})
    decision_response(conn, decision_value(req, decisions))
  end

  defp respond(conn, %{"tools" => _} = req, test_pid, script, _decisions) do
    send(test_pid, {:chat_request, req})
    {content, calls} = Agent.get_and_update(script, fn [t | rest] -> {t, rest} end)
    chat_response(conn, content, calls)
  end

  defp decision_value(req, decisions) do
    system = req["messages"] |> hd() |> Map.get("content")

    Enum.find_value(decisions, "other", fn {needle, value} ->
      if String.contains?(system, needle), do: value
    end)
  end

  defp decision_response(conn, value) do
    tokens = [~s({"), "value", ~s(":), ~s( "), value, ~s("})]

    logprobs =
      for t <- tokens do
        tops = if t == value, do: [%{"token" => value, "logprob" => :math.log(0.97)}], else: []
        %{"token" => t, "logprob" => -0.01, "top_logprobs" => tops}
      end

    Req.Test.json(conn, %{
      "message" => %{"content" => ~s({"value": "#{value}"})},
      "prompt_eval_count" => 50,
      "eval_count" => 5,
      "logprobs" => logprobs
    })
  end

  # Streamed NDJSON, split into chunks like the real API.
  defp chat_response(conn, content, calls) do
    {a, b} = String.split_at(content, div(String.length(content), 2))

    lines =
      [
        %{"message" => %{"role" => "assistant", "content" => a}, "done" => false},
        %{"message" => %{"role" => "assistant", "content" => b}, "done" => false}
      ] ++
        if(calls == [],
          do: [],
          else: [
            %{
              "message" => %{
                "role" => "assistant",
                "content" => "",
                "tool_calls" =>
                  for(
                    {name, args} <- calls,
                    do: %{"function" => %{"name" => name, "arguments" => args}}
                  )
              },
              "done" => false
            }
          ]
        ) ++ [%{"done" => true, "prompt_eval_count" => 100, "eval_count" => 10}]

    body = Enum.map_join(lines, "\n", &JSON.encode!/1) <> "\n"

    conn
    |> Plug.Conn.put_resp_content_type("application/x-ndjson")
    |> Plug.Conn.send_resp(200, body)
  end

  defp run_chat(log, ws, cfg, input, decider \\ [deciders: []]) do
    runner = {Local, chat: cfg, decider: decider}
    input = Map.merge(%{cwd: ws}, input)
    {:ok, id} = RunSupervisor.start_run(Chat, input, run_id: run_id(), log: log, runner: runner)
    id
  end

  defp kinds(log, id),
    do: for({_, "effect_requested", {:effect_requested, e}} <- Log.read_run(log, id), do: e.kind)

  # --- tools -------------------------------------------------------------------------------

  test "edit replaces exactly one occurrence and refuses ambiguity", %{ws: ws} do
    File.write!(Path.join(ws, "a.txt"), "one two two")

    assert %{ok: true} = Local.run(Effect.edit("a.txt", "one", "1", cwd: ws), [])
    assert File.read!(Path.join(ws, "a.txt")) == "1 two two"

    assert %{ok: false, error: "old_text matches 2 times" <> _} =
             Local.run(Effect.edit("a.txt", "two", "2", cwd: ws), [])

    assert %{ok: false, error: "old_text not found"} =
             Local.run(Effect.edit("a.txt", "zzz", "2", cwd: ws), [])

    assert %{ok: false, error: :outside_workspace} =
             Local.run(Effect.edit("../x", "a", "b", cwd: ws), [])
  end

  test "the transcript shows an edit as a compact diff" do
    event = %{
      "event" => "effect_requested",
      "run" => "ses-x/t1",
      "attrs" => %{
        "kind" => "edit",
        "args" => %{"path" => "a.py", "old" => "x = 1", "new" => "x = 2\ny = 3"}
      }
    }

    assert Render.line(event) == "  edit a.py\n    - x = 1\n    + x = 2\n    + y = 3\n"
  end

  # --- the chat machine --------------------------------------------------------------------

  test "chat: a safe bash call runs, its output goes back to the model, then it answers", %{
    ws: ws
  } do
    log = start_log!()
    File.write!(Path.join(ws, "hello.txt"), "hi")
    Xeito.Events.subscribe(:all)

    cfg =
      ollama(self(), [
        {"Let me look.", [{"bash", %{"command" => "ls"}}]},
        {"There is hello.txt.", []}
      ])

    id = run_chat(log, ws, cfg, %{prompt: "What is here?"})

    await_exit(id)
    assert {:ok, %{state: :answered, ctx: ctx}} = Run.result(log, id)
    assert ctx.answer == "There is hello.txt."
    assert kinds(log, id) == [:chat, :decide, :bash, :chat]

    # Chat results carry their time to the first chunk (the status bar's reply latency).
    [first_chat | _] =
      for {_, "effect_completed", {:effect_completed, _, %{content: _} = r}} <-
            Log.read_run(log, id),
          do: r

    assert is_integer(first_chat.first_token_ms) and
             first_chat.first_token_ms <= first_chat.latency_ms

    assert_received {:chat_request, first}

    assert [%{"role" => "system"}, %{"role" => "user", "content" => "What is here?"}] =
             first["messages"]

    assert Enum.map(first["tools"], & &1["function"]["name"]) == ~w(read write edit bash)

    assert_received {:chat_request, second}
    tool = List.last(second["messages"])
    assert tool["role"] == "tool" and tool["tool_name"] == "bash"
    assert tool["content"] =~ "hello.txt"

    # Streamed model output is published as deltas (not logged).
    assert_received {:xeito, ^id, %{type: "delta", attrs: %{"text" => "Let me"}}}
  end

  test "chat: a forbidden command is never run; the model is told and answers", %{ws: ws} do
    log = start_log!()
    calls = [{"bash", %{"command" => "rm -rf /"}}, {"read", %{"path" => "x"}}]
    cfg = ollama(self(), [{"", calls}, {"I will not do that.", []}])
    id = run_chat(log, ws, cfg, %{prompt: "clean up"})

    await_exit(id)
    assert {:ok, %{state: :answered}} = Run.result(log, id)
    assert kinds(log, id) == [:chat, :decide, :chat]

    assert_received {:chat_request, _}
    assert_received {:chat_request, second}
    [blocked, skipped] = Enum.take(second["messages"], -2)
    assert blocked["content"] =~ "forbidden"
    assert skipped["content"] =~ "skipped"
  end

  test "chat: a command for review waits for a human; approved, it runs", %{ws: ws} do
    log = start_log!()
    cfg = ollama(self(), [{"", [{"bash", %{"command" => "touch made.txt"}}]}, {"Done.", []}])
    id = run_chat(log, ws, cfg, %{prompt: "make a file"})

    eventually(fn -> Run.whereis(id) && Run.snapshot(id).leaf == :ask_human end)
    assert %{current: %{name: "bash"}} = Run.snapshot(id).ctx
    refute File.exists?(Path.join(ws, "made.txt"))

    assert {:ok, :executing} = Run.send_event(id, :approved, %{}, :human)
    await_exit(id)
    assert File.exists?(Path.join(ws, "made.txt"))
    assert {:ok, %{state: :answered}} = Run.result(log, id)
  end

  test "chat: invalid tool calls are answered with an error, and max_steps bounds the loop", %{
    ws: ws
  } do
    log = start_log!()
    bad = {"", [{"teleport", %{"to" => "mars"}}]}
    cfg = ollama(self(), [bad, bad, bad])
    id = run_chat(log, ws, cfg, %{prompt: "go", max_steps: 2})

    await_exit(id)
    assert {:ok, %{state: :answered, ctx: ctx}} = Run.result(log, id)
    assert ctx.answer =~ "max_steps"

    assert_received {:chat_request, _}
    assert_received {:chat_request, second}
    assert List.last(second["messages"])["content"] =~ "unknown tool"
  end

  # --- delegation: fix_failing_test hands the fix to a chat child run ------------------------

  test "fix_failing_test delegates the fix to a chat run and verifies it", %{ws: ws} do
    log = start_log!()
    File.write!(Path.join(ws, "status.txt"), "broken\n")

    edit = {"edit", %{"path" => "status.txt", "old_text" => "broken", "new_text" => "fixed"}}
    cfg = ollama(self(), [{"", [edit]}, {"Replaced broken with fixed.", []}])

    decide = fn
      %Effect{args: %{decision: Triage}} -> :code_bug
      %Effect{args: %{decision: Risk}} -> :safe
    end

    runner = {Local, chat: cfg, decide: decide}
    input = %{cwd: ws, test_cmd: "grep -q fixed status.txt", delegate: true}

    {:ok, id} =
      RunSupervisor.start_run(FixFailingTest, input, run_id: run_id(), log: log, runner: runner)

    await_exit(id)
    assert {:ok, %{state: :done, ctx: ctx}} = Run.result(log, id)
    assert ctx.triage == :code_bug
    assert %{state: :answered, answer: "Replaced broken with fixed."} = ctx.fix

    child = ctx.fix.run_id
    assert child == id <> "/e3/run"

    assert [[^id]] =
             Log.query(
               log,
               "SELECT ocel_target_id FROM object_object WHERE ocel_source_id = ?1 AND ocel_qualifier = 'part_of'",
               [child]
             )

    assert_received {:chat_request, first}
    assert List.last(first["messages"])["content"] =~ "Triage: code_bug"
  end

  # --- sessions ----------------------------------------------------------------------------

  defp session(ws, log, cfg) do
    {:ok, id} =
      Session.start(
        cwd: ws,
        log: log,
        id: "ses-test-#{System.unique_integer([:positive])}",
        chat: cfg,
        decider: [deciders: [:large], tiers: [large: cfg]]
      )

    Session.subscribe(id)
    id
  end

  defp next_event(type, timeout \\ 3_000) do
    receive do
      {:xeito, "session:" <> _, %{type: ^type} = event} -> event
    after
      timeout -> flunk("no #{type} event")
    end
  end

  test "session: prompt → Intent → chat machine → answer, with history across turns", %{ws: ws} do
    log = start_log!()
    File.write!(Path.join(ws, "AGENTS.md"), "Always answer in one sentence.")

    cfg =
      ollama(self(), [{"There are two files.", []}, {"The first one.", []}], %{
        "What does the user want" => "question"
      })

    id = session(ws, log, cfg)
    assert :ok = Session.prompt(id, "What files are here?")

    assert %{attrs: %{"value" => :question, "actor" => :large}} = next_event("intent")
    assert %{attrs: %{"machine" => "Xeito.Machines.Chat"}, run: run} = next_event("run_selected")
    assert run == id <> "/t1"
    assert %{attrs: %{"answer" => "There are two files."}} = next_event("turn_finished")

    assert_received {:chat_request, first}
    assert hd(first["messages"])["content"] =~ "Always answer in one sentence."

    assert :ok = Session.prompt(id, "Which one is first?")
    assert %{attrs: %{"answer" => "The first one."}} = next_event("turn_finished")

    assert_received {:chat_request, second}
    contents = Enum.map(second["messages"], & &1["content"])
    assert "What files are here?" in contents and "There are two files." in contents
    assert length(Session.history(id)) == 4

    # Both turns are part of the session in the log.
    assert [[2]] =
             Log.query(
               log,
               "SELECT COUNT(*) FROM object_object WHERE ocel_target_id = ?1 AND ocel_qualifier = 'part_of' AND ocel_source_id LIKE ?2",
               [id, id <> "/t_"]
             )

    Session.prompt(id, "/why")
    assert %{attrs: %{"text" => text}} = next_event("notice")
    assert text =~ "Intent: question by large"
  end

  test "session: routes failing tests to fix_failing_test and relays approvals", %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [{"", [{"bash", %{"command" => "touch approved.txt"}}]}, {"ok", []}], %{
        "What does the user want" => "edit",
        "Is this shell command safe" => "review"
      })

    id = session(ws, log, cfg)

    assert {:error, :nothing_to_approve} = Session.approve(id)
    assert :ok = Session.prompt(id, "please do something unusual")
    next_event("run_selected")
    assert %{attrs: %{"call" => %{"tool" => "bash"}}} = next_event("human_needed")
    assert {:error, :busy} = Session.prompt(id, "another")
    assert :ok = Session.prompt(id, "/approve")
    assert %{attrs: %{"answer" => "ok"}} = next_event("turn_finished")
    assert File.exists?(Path.join(ws, "approved.txt"))

    assert {FixFailingTest, _} =
             Router.route(:edit, "the checkout test is red again")

    assert {RunTests, _} = Router.route(:run, "run the tests")
    assert {Chat, _} = Router.route(:edit, "rename this function")
  end

  test "session: a stopped session is rebuilt from the log and continues its turns", %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [{"First answer.", []}, {"Second answer.", []}], %{
        "What does the user want" => "question"
      })

    id = session(ws, log, cfg)
    Session.prompt(id, "first question")
    next_event("turn_finished")
    history = Session.history(id)

    [{pid, _}] = Registry.lookup(Xeito.SessionRegistry, id)
    DynamicSupervisor.terminate_child(Xeito.SessionSupervisor, pid)

    {:ok, ^id} =
      Session.start(
        cwd: ws,
        log: log,
        id: id,
        chat: cfg,
        decider: [deciders: [:large], tiers: [large: cfg]]
      )

    assert Session.history(id) == history
    assert %{turns: 1} = Session.status(id)

    Session.prompt(id, "second question")
    run = id <> "/t2"
    assert_receive {:xeito, _, %{type: "run_selected", run: ^run}}, 3_000
    assert %{attrs: %{"answer" => "Second answer."}} = next_event("turn_finished")

    assert_received {:chat_request, _}
    assert_received {:chat_request, second}
    assert "first question" in Enum.map(second["messages"], & &1["content"])
  end

  test "session: approving at fix_failing_test's ask_human continues the machine", %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [{"Fixed.", []}], %{
        "What does the user want" => "edit",
        "Why is this test failing" => "env_problem"
      })

    {:ok, id} =
      Session.start(
        cwd: ws,
        log: log,
        id: "ses-test-#{System.unique_integer([:positive])}",
        chat: cfg,
        # Fails once (reproduce), passes afterwards (verify), so the run ends cleanly.
        test_cmd: "test -f .ok || (touch .ok; echo 'service unavailable'; exit 1)",
        decider: [deciders: [:large], tiers: [large: cfg]]
      )

    Session.subscribe(id)
    Session.prompt(id, "the pricing test is failing")
    next_event("human_needed")
    assert :ok = Session.approve(id)

    # :answered took it back to working: the fix is delegated, verified, and the turn ends.
    assert_receive {:xeito, _, %{type: "transition", attrs: %{"event_name" => :answered}}}, 3_000
    assert %{attrs: %{"status" => :done}} = next_event("turn_finished")
  end

  # --- the client API over the Unix socket -------------------------------------------------

  test "api: a client starts a session, prompts, and receives the streamed events", %{ws: ws} do
    log = start_log!()
    cfg = ollama(self(), [{"Hello from the model.", []}], %{"What does the user want" => "other"})
    dir = Path.join(System.tmp_dir!(), "xa-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "x.sock")

    start_supervised!(
      {Xeito.Api,
       socket: path,
       name: :"api_#{System.unique_integer([:positive])}",
       session: [log: log, chat: cfg, decider: [deciders: [:large], tiers: [large: cfg]]]}
    )

    assert Bitwise.band(File.stat!(path).mode, 0o077) == 0
    assert Bitwise.band(File.stat!(dir).mode, 0o077) == 0

    {:ok, client} = Client.connect(path)

    assert %{"ok" => true, "session" => session} =
             Client.request(client, %{"cmd" => "start", "cwd" => ws})

    assert %{"ok" => true} =
             Client.request(client, %{
               "cmd" => "prompt",
               "session" => session,
               "text" => "hi"
             })

    events = collect_until("turn_finished")
    types = Enum.map(events, & &1["event"])
    assert "intent" in types and "run_selected" in types and "delta" in types
    assert List.last(events)["attrs"]["answer"] == "Hello from the model."

    text = Enum.map_join(events, &Render.line/1)
    assert text =~ "◆ intent: other (rule 1.00)"
    assert text =~ "Hello from the model."
    assert text =~ "✓ answered"

    assert %{"ok" => false, "error" => "no such session"} =
             Client.request(client, %{"cmd" => "status", "session" => "nope"})

    assert %{"ok" => true, "status" => %{"history" => 2}} =
             Client.request(client, %{"cmd" => "status", "session" => session})
  end

  test "an idle session closes, frees its budget, and a client's next prompt resumes it", %{
    ws: ws
  } do
    log = start_log!()
    cfg = ollama(self(), [{"one", []}, {"two", []}], %{"What does the user want" => "other"})
    dir = Path.join(System.tmp_dir!(), "xa-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "x.sock")

    defaults = [
      log: log,
      chat: cfg,
      decider: [deciders: [:large], tiers: [large: cfg]],
      idle_timeout: 200
    ]

    start_supervised!(
      {Xeito.Api,
       socket: path, name: :"api_#{System.unique_integer([:positive])}", session: defaults}
    )

    {:ok, client} = Client.connect(path)

    %{"ok" => true, "session" => session} =
      Client.request(client, %{"cmd" => "start", "cwd" => ws})

    Xeito.Budget.add(session, :usd, 0.01)

    %{"ok" => true} =
      Client.request(client, %{"cmd" => "prompt", "session" => session, "text" => "hi"})

    collect_until("turn_finished")

    collect_until("closed")
    eventually(fn -> Registry.lookup(Xeito.SessionRegistry, session) == [] end)
    assert Xeito.Budget.get(session, :usd) == 0

    # The client never noticed: its next prompt resumes the session from the log.
    assert %{"ok" => true} =
             Client.request(client, %{"cmd" => "prompt", "session" => session, "text" => "again"})

    events = collect_until("turn_finished")
    assert List.last(events)["attrs"]["answer"] == "two"

    assert %{"ok" => true, "status" => %{"turns" => 2}} =
             Client.request(client, %{"cmd" => "status", "session" => session})
  end

  defp collect_until(type, acc \\ []) do
    receive do
      {:xeito_event, %{"event" => ^type} = e} -> Enum.reverse([e | acc])
      {:xeito_event, e} -> collect_until(type, [e | acc])
    after
      3_000 -> flunk("no #{type}; got #{inspect(Enum.map(acc, & &1["event"]))}")
    end
  end
end
