defmodule Xeito.HarnessTest do
  # Chat calls happen in supervised effect tasks, so Req.Test stubs are shared (serial).
  use Xeito.Case, async: false

  alias Xeito.Client
  alias Xeito.Client.Render
  alias Xeito.Decisions.Risk
  alias Xeito.Decisions.Triage
  alias Xeito.Effect
  alias Xeito.Effects.Local
  alias Xeito.Log
  alias Xeito.Machines.Chat
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Machines.RunTests
  alias Xeito.Run
  alias Xeito.RunSupervisor
  alias Xeito.Session
  alias Xeito.Session.Allowed
  alias Xeito.Session.Git
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
    # A turn may be a function, called when the model is asked: a test can hold a reply back.
    {content, calls} =
      case Agent.get_and_update(script, fn [t | rest] -> {t, rest} end) do
        reply when is_function(reply, 0) -> reply.()
        reply -> reply
      end

    chat_response(conn, content, calls)
  end

  defp decision_value(req, decisions) do
    system = req["messages"] |> hd() |> Map.get("content")

    value =
      Enum.find_value(decisions, "other", fn {needle, value} ->
        if String.contains?(system, needle), do: value
      end)

    # A function decides when it is called: a test can hold a decision back.
    if is_function(value, 0), do: value.(), else: value
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
          # --- tools -------------------------------------------------------------------------------
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

  defp kinds(log, id), do: for({_, "effect_requested", {:effect_requested, e}} <- Log.read_run(log, id), do: e.kind)

  test "edit replaces exactly one occurrence and refuses ambiguity", %{ws: ws} do
    File.write!(Path.join(ws, "a.txt"), "one two two")

    assert %{ok: true} = Local.run(Effect.edit("a.txt", "one", "1", cwd: ws), [])
    # --- the chat machine --------------------------------------------------------------------
    assert File.read!(Path.join(ws, "a.txt")) == "1 two two"

    assert %{ok: false, error: "old_text matches 2 times" <> _} =
             Local.run(Effect.edit("a.txt", "two", "2", cwd: ws), [])

    assert %{ok: false, error: "old_text not found; nothing similar" <> _} =
             Local.run(Effect.edit("a.txt", "zzz", "2", cwd: ws), [])

    assert %{ok: false, error: :outside_workspace} =
             Local.run(Effect.edit("../x", "a", "b", cwd: ws), [])
  end

  test "a missing workspace is reported, and nothing is started in it" do
    gone = Path.join(System.tmp_dir!(), "xeito-gone-#{System.unique_integer([:positive])}")

    assert %{exit_status: 127, output: "workspace missing: " <> _} =
             Local.run(Effect.bash("ls", cwd: gone), [])

    assert Git.status(gone) == nil
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

  test "chat: after edits the checks run before the answer; a failure goes back to the model",
       %{ws: ws} do
    log = start_log!()
    File.write!(Path.join(ws, "a.txt"), "bug")
    edit = fn old, new -> {"edit", %{"path" => "a.txt", "old_text" => old, "new_text" => new}} end

    cfg =
      ollama(self(), [
        {"Editing.", [edit.("bug", "wip")]},
        {"Done.", []},
        {"Fixing.", [edit.("wip", "fixed")]},
        {"Fixed now.", []}
      ])

    id = run_chat(log, ws, cfg, %{prompt: "Fix a.txt", verify: "grep -q fixed a.txt"})

    await_exit(id)
    assert {:ok, %{state: :answered, ctx: ctx}} = Run.result(log, id)
    assert ctx.answer == "Fixed now."
    assert ctx.checks == %{cmd: "grep -q fixed a.txt", exit_status: 0, passed: true}
    assert kinds(log, id) == [:decide, :chat, :edit, :chat, :bash, :chat, :edit, :chat, :bash]

    # The third request carries the failed checks as the user's reply.
    requests =
      for _ <- 1..4 do
        assert_received {:chat_request, request}
        request
      end

    failure = requests |> Enum.at(2) |> Map.fetch!("messages") |> List.last()
    assert failure["role"] == "user" and failure["content"] =~ "fail after your edits"
  end

  test "chat: a turn stopped at its step limit with failing checks gets a budget to fix them",
       %{ws: ws} do
    log = start_log!()
    File.write!(Path.join(ws, "a.txt"), "bug")
    edit = fn old, new -> {"edit", %{"path" => "a.txt", "old_text" => old, "new_text" => new}} end

    cfg =
      ollama(self(), [
        {"Editing.", [edit.("bug", "wip")]},
        # The step limit (2) is reached with a call: it is not run, and the checks run instead.
        {"More.", [edit.("wip", "wip2")]},
        {"Fixing.", [edit.("wip", "fixed")]},
        {"Fixed.", []}
      ])

    id = run_chat(log, ws, cfg, %{prompt: "Fix a.txt", verify: "grep -q fixed a.txt", max_steps: 2})

    await_exit(id)
    assert {:ok, %{state: :answered, ctx: ctx}} = Run.result(log, id)
    assert ctx.answer == "Fixed."
    assert ctx.checks.passed
    assert ctx.steps == 4
    assert File.read!(Path.join(ws, "a.txt")) == "fixed"

    requests =
      for _ <- 1..3 do
        assert_received {:chat_request, request}
        request
      end

    failure = requests |> List.last() |> Map.fetch!("messages") |> List.last()
    assert failure["content"] =~ "You have 4 more model turns"
  end

  test "chat: a turn stopped at its step limit closes with the model's summary, without tools",
       %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [
        {"Looking.", [{"bash", %{"command" => "ls"}}]},
        {"More.", [{"bash", %{"command" => "pwd"}}]},
        {"Found two files; next I would read a.txt.", []}
      ])

    id = run_chat(log, ws, cfg, %{prompt: "Look around", max_steps: 2})
    await_exit(id)
    assert {:ok, %{state: :answered, ctx: ctx}} = Run.result(log, id)

    assert ctx.answer ==
             "Stopped after 2 model turns (max_steps).\n\nFound two files; next I would read a.txt."

    requests =
      for _ <- 1..3,
          do:
            (
              assert_received({:chat_request, r})
              r
            )

    wrap_up = List.last(requests)
    assert wrap_up["tools"] == []
    assert List.last(wrap_up["messages"])["content"] =~ "Do not call tools"
  end

  test "chat: an exact repeat of a call is not run again; the model is pointed to the result",
       %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [
        {"Look.", [{"bash", %{"command" => "ls"}}]},
        {"Again.", [{"bash", %{"command" => "ls"}}]},
        {"Done.", []}
      ])

    id = run_chat(log, ws, cfg, %{prompt: "Look around"})
    await_exit(id)
    assert {:ok, %{ctx: %{answer: "Done."}}} = Run.result(log, id)
    assert kinds(log, id) == [:decide, :chat, :decide, :bash, :chat, :chat]

    requests =
      for _ <- 1..3,
          do:
            (
              assert_received({:chat_request, r})
              r
            )

    assert List.last(Enum.at(requests, 2)["messages"])["content"] =~ "you already made this exact call"
  end

  test "chat: tool calls that keep failing end the turn; an empty answer is noted", %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [
        {"", [{"read", %{"path" => "a.txt"}}]},
        {"", [{"read", %{"path" => "a.txt"}}]},
        {"", [{"read", %{"path" => "a.txt"}}]},
        {"I cannot read files in this turn.", []}
      ])

    id = run_chat(log, ws, cfg, %{prompt: "go ahead", tools: false})
    await_exit(id)
    assert {:ok, %{ctx: ctx}} = Run.result(log, id)

    assert ctx.answer ==
             "Stopped: the model kept making tool calls that could not run.\n\nI cannot read files in this turn."

    [_first, second, third | _] =
      for _ <- 1..4,
          do:
            (
              assert_received({:chat_request, r})
              r
            )

    assert List.last(second["messages"])["content"] == "error: no tools are available in this turn; answer in text"
    # Once, in a turn that changed nothing, failing again is answered with a nudge, not an end.
    assert List.last(third["messages"])["content"] =~ "You already have the results you need"

    empty = run_chat(log, ws, ollama(self(), [{"  ", []}]), %{prompt: "hm"})
    await_exit(empty)
    assert {:ok, %{ctx: %{answer: "(The model ended this turn without an answer.)"}}} = Run.result(log, empty)
  end

  test "session: the user's skills are not listed; one that fits is chosen by the Skill decision and suggested",
       %{ws: ws} do
    home = Path.join(ws, "home")
    dir = Path.join([home, ".agents", "skills", "diagnosing-bugs"])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "SKILL.md"), """
    ---
    name: diagnosing-bugs
    description: Diagnosis loop for hard bugs and performance regressions. Use when the user says diagnose.
    ---
    Reproduce first.
    """)

    previous = Application.get_env(:xeito, :skills_home)
    Application.put_env(:xeito, :skills_home, home)
    on_exit(fn -> Application.put_env(:xeito, :skills_home, previous) end)

    log = start_log!()
    decisions = %{"What does the user want" => "explain", "A skill is a set of instructions" => "first"}
    cfg = ollama(self(), [{"Let me reproduce it first.", []}], decisions)

    {:ok, id} =
      Session.start(
        cwd: ws,
        log: log,
        id: "ses-test-#{System.unique_integer([:positive])}",
        chat: cfg,
        decider: [deciders: [:local], tiers: [local: cfg]]
      )

    Session.subscribe(id)
    :ok = Session.prompt(id, "the export got slow after the deploy; diagnose this performance regression")
    assert %{attrs: %{"answer" => "Let me reproduce it first."}} = next_event("turn_finished")

    assert_received {:chat_request, %{"messages" => [system | _] = messages}}
    refute system["content"] =~ "diagnosing-bugs"

    assert List.last(messages)["content"] =~
             "load it with the skill tool before you start: diagnosing-bugs: Diagnosis loop"
  end

  test "session: a go-ahead after an unfinished turn continues it with tools; only rule small talk drops tools",
       %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(
        self(),
        [
          {"Looking.", [{"bash", %{"command" => "ls"}}]},
          {"More.", [{"bash", %{"command" => "pwd"}}]},
          {"Found two files.", []},
          {"Continuing: done.", []},
          {"Interesting indeed.", []},
          {"You're welcome.", []}
        ],
        %{"What does the user want" => "other"}
      )

    {:ok, id} =
      Session.start(
        cwd: ws,
        log: log,
        id: "ses-test-#{System.unique_integer([:positive])}",
        chat: cfg,
        decider: [deciders: [:local], tiers: [local: cfg]],
        max_steps: 2
      )

    Session.subscribe(id)
    :ok = Session.prompt(id, "investigate the files")
    next_event("intent")
    assert %{attrs: %{"answer" => "Stopped after 2 model turns" <> _}} = next_event("turn_finished")
    for _ <- 1..3, do: assert_received({:chat_request, _})

    # "go ahead" continues by rule, with tools (the model would have said `other`).
    :ok = Session.prompt(id, "go ahead")
    assert %{attrs: %{"actor" => :rule, "model" => "rule:continuation"}} = next_event("intent")
    assert %{attrs: %{"answer" => "Continuing: done."}} = next_event("turn_finished")
    assert_received {:chat_request, continued}
    assert continued["tools"] != []

    # The model's `other` keeps the tools; the small-talk rule drops them.
    :ok = Session.prompt(id, "interesting")
    assert %{attrs: %{"value" => :other, "actor" => :local}} = next_event("intent")
    next_event("turn_finished")
    assert_received {:chat_request, other}
    assert other["tools"] != []

    :ok = Session.prompt(id, "thanks")
    assert %{attrs: %{"actor" => :rule}} = next_event("intent")
    next_event("turn_finished")
    assert_received {:chat_request, thanks}
    assert thanks["tools"] == []
  end

  test "chat: a turn without edits answers without running the checks", %{ws: ws} do
    log = start_log!()
    cfg = ollama(self(), [{"Just an answer.", []}])
    id = run_chat(log, ws, cfg, %{prompt: "hi", verify: "false"})

    await_exit(id)
    assert {:ok, %{state: :answered, ctx: ctx}} = Run.result(log, id)
    refute Map.has_key?(ctx, :checks)
    assert kinds(log, id) == [:decide, :chat]
  end

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
    assert kinds(log, id) == [:decide, :chat, :decide, :bash, :chat]

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
    # Xeito's bookkeeping on messages (the result's ref, what it was) never reaches the model.
    assert tool |> Map.keys() |> Enum.sort() == ["content", "role", "tool_name"]

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
    assert kinds(log, id) == [:decide, :chat, :decide, :chat]

    assert_received {:chat_request, _}
    assert_received {:chat_request, second}
    [blocked, skipped] = Enum.take(second["messages"], -2)
    assert blocked["content"] =~ "forbidden"
    assert skipped["content"] =~ "skipped"
  end

  # `sh -c '…'` goes to review: its writes are not visible in the command (a plain `touch` inside
  # the workspace would be safe by rule).
  test "chat: a command for review waits for a human; approved, it runs", %{ws: ws} do
    log = start_log!()
    cfg = ollama(self(), [{"", [{"bash", %{"command" => "sh -c 'touch made.txt'"}}]}, {"Done.", []}])
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

  test "fix_failing_test delegates the fix to a chat run and verifies it", %{ws: ws} do
    # --- delegation: fix_failing_test hands the fix to a chat child run ------------------------
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

  defp session(ws, log, cfg) do
    # --- sessions ----------------------------------------------------------------------------
    {:ok, id} =
      Session.start(
        cwd: ws,
        log: log,
        id: "ses-test-#{System.unique_integer([:positive])}",
        chat: cfg,
        decider: [deciders: [:local], tiers: [local: cfg]]
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

    assert %{attrs: %{"value" => :question, "actor" => :local}} = next_event("intent")
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
    assert text =~ "Intent: question by local"
  end

  test "session: routes failing tests to fix_failing_test and relays approvals", %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [{"", [{"bash", %{"command" => "sh -c 'touch approved.txt'"}}]}, {"ok", []}], %{
        "What does the user want" => "edit",
        "Is this shell command safe" => "review"
      })

    id = session(ws, log, cfg)

    assert {:error, :nothing_to_approve} = Session.approve(id)
    assert :ok = Session.prompt(id, "please do something unusual")
    next_event("run_selected")
    assert %{attrs: %{"call" => %{"tool" => "bash"}}} = next_event("human_needed")
    assert :ok = Session.prompt(id, "/approve")
    assert %{attrs: %{"answer" => "ok"}} = next_event("turn_finished")
    assert File.exists?(Path.join(ws, "approved.txt"))

    assert {FixFailingTest, _} =
             Router.route(:edit, "the checkout test is red again")

    assert {RunTests, _} = Router.route(:run, "run the tests")
    assert {Chat, _} = Router.route(:edit, "rename this function")
  end

  test "session: a review says how long the command will get, when the model set it", %{ws: ws} do
    log = start_log!()
    call = {"", [{"bash", %{"command" => "sh -c 'touch slow.txt'", "timeout_s" => 9_999}}]}

    cfg =
      ollama(self(), [call, {"ok", []}], %{"What does the user want" => "edit", "Is this shell command safe" => "review"})

    id = session(ws, log, cfg)

    :ok = Session.prompt(id, "please do something unusual")
    max = Xeito.Tools.max_bash_timeout_s()
    assert %{attrs: %{"call" => %{"runs_for_s" => ^max}}} = next_event("human_needed")
    :ok = Session.prompt(id, "/deny")
    next_event("turn_finished")
  end

  test "session: a command allowed for the session or always is not asked about again", %{ws: ws} do
    log = start_log!()
    touch = fn name -> {"", [{"bash", %{"command" => "sh -c 'touch #{name}'"}}]} end
    one = "sh -c 'touch one.txt'"
    # Six turns: three in the first session, three in a second one in the same workspace.
    turns = [touch.("one.txt"), {"ok", []}, touch.("one.txt"), {"ok", []}, touch.("two.txt"), {"ok", []}]
    later = [touch.("two.txt"), {"ok", []}, touch.("one.txt"), {"ok", []}]
    decisions = %{"What does the user want" => "edit", "Is this shell command safe" => "review"}
    cfg = ollama(self(), turns ++ later, decisions)
    id = session(ws, log, cfg)

    :ok = Session.prompt(id, "please do something unusual")
    assert %{attrs: %{"call" => %{"arguments" => %{"command" => ^one}}}} = next_event("human_needed")
    :ok = Session.prompt(id, "/approve session")
    assert %{attrs: %{"text" => "approved · `" <> _ = said}} = next_event("notice")
    assert said == "approved · `#{one}` is now allowed for this session"
    next_event("turn_finished")
    assert File.exists?(Path.join(ws, "one.txt"))
    File.rm!(Path.join(ws, "one.txt"))

    # The same command again: the Risk decision still runs, the human is not asked.
    :ok = Session.prompt(id, "again, please")
    assert %{attrs: %{"text" => "· `" <> _ = said}} = next_event("notice")
    assert said == "· `#{one}` runs without asking: allowed for this session"
    next_event("turn_finished")
    assert File.exists?(Path.join(ws, "one.txt"))
    refute_received {:xeito, _, %{type: "human_needed"}}

    :ok = Session.prompt(id, "and something else unusual")
    next_event("human_needed")
    assert :ok = Session.approve(id, "always")
    assert %{attrs: %{"text" => said}} = next_event("notice")
    assert said == "approved · `sh -c 'touch two.txt'` is now always allowed in this workspace (.xeito/allowed.json)"
    next_event("turn_finished")
    assert Allowed.always(ws) == ["sh -c 'touch two.txt'"]

    # A later session in the workspace: the `always` command runs without asking, the session's asks again.
    other = session(ws, log, cfg)
    :ok = Session.prompt(other, "please do something unusual")
    assert %{attrs: %{"text" => said}} = next_event("notice")
    assert said == "· `sh -c 'touch two.txt'` runs without asking: always allowed in this workspace (.xeito/allowed.json)"
    next_event("turn_finished")

    :ok = Session.prompt(other, "and once more")
    assert %{attrs: %{"call" => %{"arguments" => %{"command" => ^one}}}} = next_event("human_needed")
    :ok = Session.deny(other)
    next_event("turn_finished")
  end

  test "session: a text answer to a review is not run; the model is told what to do instead", %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [{"", [{"bash", %{"command" => "sh -c 'touch nope.txt'"}}]}, {"Listed instead.", []}], %{
        "What does the user want" => "edit",
        "Is this shell command safe" => "review"
      })

    id = session(ws, log, cfg)
    :ok = Session.prompt(id, "make a file")
    next_event("human_needed")

    assert :ok = Session.prompt(id, "don't, just list the files")
    assert %{attrs: %{"answer" => "Listed instead."}} = next_event("turn_finished")
    refute File.exists?(Path.join(ws, "nope.txt"))

    assert_receive {:chat_request, _first}
    assert_receive {:chat_request, %{"messages" => messages}}

    assert %{"role" => "tool", "content" => "not run: instead of approving, the user said: don't, just list the files"} =
             List.last(messages)
  end

  test "session: /steer reaches the running chat turn at its next model call", %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [{"", [{"bash", %{"command" => "sleep 0.1"}}]}, {"Using pytest.", []}], %{
        "What does the user want" => "edit",
        "Is this shell command safe" => "review"
      })

    id = session(ws, log, cfg)
    :ok = Session.prompt(id, "wait a bit")
    next_event("human_needed")

    :ok = Session.prompt(id, "/steer use pytest")
    assert %{attrs: %{"text" => "use pytest"}} = next_event("steered")
    :ok = Session.prompt(id, "/approve")
    assert %{attrs: %{"answer" => "Using pytest."}} = next_event("turn_finished")

    assert_receive {:chat_request, _first}
    assert_receive {:chat_request, %{"messages" => messages}}
    assert Enum.any?(messages, &(&1["content"] == "(The user, while you were working:) use pytest"))
  end

  test "session: a steer the turn ended before delivering is queued, then sent as the next prompt", %{ws: ws} do
    log = start_log!()
    test = self()

    held = fn ->
      send(test, {:asking, self()})

      # Held until the test lets it go; a failing test must not leave the model queue blocked.
      receive do
        :go -> {"All done.", []}
      after
        5_000 -> {"(timed out)", []}
      end
    end

    cfg = ollama(self(), [held, {"Pytest it is.", []}], %{"What does the user want" => "question"})
    id = session(ws, log, cfg)
    :ok = Session.prompt(id, "summarise")
    assert_receive {:asking, model}, 3_000

    :ok = Session.prompt(id, "/steer use pytest")
    next_event("steered")
    send(model, :go)

    assert %{attrs: %{"answer" => "All done."}} = next_event("turn_finished")
    assert %{attrs: %{"text" => "use pytest"}} = next_event("queued")
    assert %{attrs: %{"text" => "use pytest", "outcome" => "sent"}} = next_event("dequeued")
    assert %{attrs: %{"answer" => "Pytest it is."}} = next_event("turn_finished")
  end

  test "session: /halt stops a turn mid-command; a go-ahead then continues it cleanly", %{ws: ws} do
    log = start_log!()

    cfg =
      ollama(self(), [{"", [{"bash", %{"command" => "sleep 5"}}]}, {"Resumed.", []}], %{
        "What does the user want" => "edit",
        "Is this shell command safe" => "review"
      })

    id = session(ws, log, cfg)
    :ok = Session.prompt(id, "wait a bit")
    # `sleep` is not safe by rule, and a model can only raise Risk: it goes to review first.
    next_event("human_needed")
    :ok = Session.prompt(id, "/approve")
    assert_receive {:xeito, _, %{type: "effect_requested", attrs: %{"kind" => :bash}}}, 3_000
    # A line typed meanwhile is queued; the halted turn holds it, and a go-ahead does not send it.
    assert :ok = Session.prompt(id, "another")

    assert :ok = Session.prompt(id, "/halt")
    assert %{attrs: %{"status" => :halted, "answer" => "Halted by the user."}} = next_event("turn_finished")

    # The halted turn is unfinished, so a go-ahead continues it; its dangling call is not resent.
    :ok = Session.prompt(id, "go ahead")
    assert %{attrs: %{"answer" => "Resumed."}} = next_event("turn_finished")
    assert_receive {:chat_request, _first}
    assert_receive {:chat_request, %{"messages" => messages}}
    refute Enum.any?(messages, &match?(%{"tool_calls" => [_ | _]}, &1))
    assert Enum.any?(messages, &(&1["role"] == "assistant" and &1["content"] =~ "Halted by the user"))
  end

  test "session: /halt during the intent decision ends the turn; the late decision is dropped", %{ws: ws} do
    log = start_log!()
    test = self()

    held = fn ->
      send(test, {:deciding, self()})

      # Held, but never for long: model calls share the local tier's queue with later tests.
      receive do
        :go -> "edit"
      after
        3_000 -> "edit"
      end
    end

    cfg = ollama(self(), [{"Should not run.", []}], %{"What does the user want" => held})
    id = session(ws, log, cfg)
    :ok = Session.prompt(id, "do something")
    assert_receive {:deciding, decider}, 3_000

    assert :ok = Session.prompt(id, "/halt")
    assert %{attrs: %{"status" => :halted}} = next_event("turn_finished")

    send(decider, :go)
    refute_receive {:xeito, _, %{type: "run_selected"}}, 500
    refute_received {:chat_request, _}
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
        decider: [deciders: [:local], tiers: [local: cfg]]
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
        decider: [deciders: [:local], tiers: [local: cfg]]
      )

    Session.subscribe(id)
    Session.prompt(id, "the pricing test is failing")
    next_event("human_needed")
    assert :ok = Session.approve(id)

    # :answered took it back to working: the fix is delegated, verified, and the turn ends.
    assert_receive {:xeito, _, %{type: "transition", attrs: %{"event_name" => :answered}}}, 3_000
    assert %{attrs: %{"status" => :done}} = next_event("turn_finished")
  end

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
       session: [log: log, chat: cfg, decider: [deciders: [:local], tiers: [local: cfg]]]}
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

    # --- the client API over the Unix socket -------------------------------------------------

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
      decider: [deciders: [:local], tiers: [local: cfg]],
      idle_timeout: 200
    ]

    start_supervised!({Xeito.Api, socket: path, name: :"api_#{System.unique_integer([:positive])}", session: defaults})

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
