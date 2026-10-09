defmodule Xeito.SessionCommandsTest do
  use Xeito.Case, async: false

  alias Xeito.Decisions.Risk
  alias Xeito.Session
  alias Xeito.Session.Allowed
  alias Xeito.Session.Directory

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    log = start_log!()
    {:ok, id} = Session.start(cwd: ws, log: log, id: "ses-cmd-#{System.unique_integer([:positive])}")
    Session.subscribe(id)
    %{id: id, log: log, ws: ws}
  end

  # The text of the next notice or error the session emits.
  defp reply(id, command) do
    :ok = Session.prompt(id, command)
    assert_receive {:xeito, _, %{type: type, attrs: %{"text" => text}}} when type in ["notice", "error"], 2_000
    {String.to_atom(type), text}
  end

  describe "a daemon whose code changed on disk after it started" do
    setup do
      # Every compiled file is newer than the epoch.
      Application.put_env(:xeito, :code_loaded_at, 0)
      on_exit(fn -> Application.delete_env(:xeito, :code_loaded_at) end)
    end

    test "says so once, with the first prompt", %{id: id} do
      :ok = Session.prompt(id, "/help")

      assert_receive {:xeito, _,
                      %{type: "notice", attrs: %{"text" => "· the daemon's code changed on disk" <> _ = text}}},
                     2_000

      assert text =~ "restart it"
      assert_receive {:xeito, _, %{type: "notice", attrs: %{"text" => "/" <> _}}}, 2_000

      :ok = Session.prompt(id, "/help")
      refute_receive {:xeito, _, %{type: "notice", attrs: %{"text" => "· the daemon's code" <> _}}}, 300
    end
  end

  describe "/undo and /redo: this session's steps in the workspace" do
    # An agent step of this session that writes `path` (as the local runner records one).
    defp agent_step(ws, id, path, text),
      do: Xeito.Undo.step(ws, id, "write #{path}", fn -> File.write!(Path.join(ws, path), text) end)

    test "/undo n reverts the last n steps and tells the model; /redo puts them back", %{id: id, ws: ws} do
      agent_step(ws, "#{id}/t1/e1", "a.txt", "a\n")
      agent_step(ws, "#{id}/t1/e2", "b.txt", "b\n")

      assert reply(id, "/undo 2") == {:notice, "undid 2 steps (/redo reverses this):\n  write b.txt\n  write a.txt\n"}
      refute File.exists?(Path.join(ws, "a.txt"))
      refute File.exists?(Path.join(ws, "b.txt"))

      assert %{role: "user", content: "(I undid 2 of your steps: write b.txt; write a.txt. " <> _} =
               List.last(Session.history(id))

      assert reply(id, "/redo") == {:notice, "redid 1 step:\n  write a.txt\n"}
      assert File.read!(Path.join(ws, "a.txt")) == "a\n"
      assert %{content: "(I redid 1 of your steps that I had undone: write a.txt.)"} = List.last(Session.history(id))
    end

    test "nothing to undo or redo, more than there is, a bad count", %{id: id, ws: ws} do
      assert reply(id, "/undo") == {:error, "nothing to undo"}
      assert reply(id, "/redo") == {:error, "nothing to redo"}
      agent_step(ws, "#{id}/t1/e1", "a.txt", "a\n")
      assert reply(id, "/undo 3") == {:error, "only 1 step to undo; nothing was undone"}

      for bad <- ["/undo two", "/undo 0", "/redo -1"] do
        assert {:error, usage} = reply(id, bad)
        assert usage =~ ~r{^/(undo|redo) \[n\]: n steps, 1 or more}
      end
    end

    test "a step whose lines the user changed since is not undone", %{id: id, ws: ws} do
      agent_step(ws, "#{id}/t1/e1", "a.txt", "a\n")
      File.write!(Path.join(ws, "a.txt"), "mine\n")

      assert reply(id, "/undo") ==
               {:error, "can't undo write a.txt: those lines changed since; nothing was undone"}

      assert File.read!(Path.join(ws, "a.txt")) == "mine\n"
    end

    test "a command a run ran is a step: /run touch x.txt, then /undo", %{id: id, ws: ws} do
      :ok = Session.prompt(id, "/run touch x.txt")
      assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
      assert File.exists?(Path.join(ws, "x.txt"))

      assert reply(id, "/undo") == {:notice, "undid 1 step (/redo reverses this):\n  bash touch x.txt\n"}
      refute File.exists?(Path.join(ws, "x.txt"))
    end

    test "files a step left out for their size are named, and left as they are", %{id: id, ws: ws} do
      Xeito.Undo.step(ws, "#{id}/t1/e1", "bash make", fn ->
        File.write!(Path.join(ws, "a.txt"), "a\n")
        File.write!(Path.join(ws, "big.bin"), :binary.copy("x", 5_000_001))
      end)

      assert reply(id, "/undo") ==
               {:notice,
                "undid 1 step (/redo reverses this):\n  bash make\n" <>
                  "not covered (over 5 MB, left as they are): big.bin\n"}

      assert File.exists?(Path.join(ws, "big.bin"))
    end

    test "undo and redo are logged, each against the step's effect and the session", %{id: id, ws: ws, log: log} do
      agent_step(ws, "#{id}/t1/e1", "a.txt", "a\n")
      agent_step(ws, "#{id}/t1/e2", "b.txt", "b\n")
      {:notice, _} = reply(id, "/undo 2")
      {:notice, _} = reply(id, "/redo")

      assert Xeito.Log.query(log, "SELECT effect_id, label FROM event_step_undone ORDER BY rowid") ==
               [["#{id}/t1/e2", "write b.txt"], ["#{id}/t1/e1", "write a.txt"]]

      effect = "#{id}/t1/e1"

      assert [[event, ^effect, "write a.txt"]] =
               Xeito.Log.query(log, "SELECT ocel_id, effect_id, label FROM event_step_redone")

      assert Xeito.Log.query(
               log,
               "SELECT ocel_object_id, ocel_qualifier FROM event_object WHERE ocel_event_id = ?1 ORDER BY 2",
               [event]
             ) ==
               [["#{id}/t1/e1", "redoes"], [id, "within"]]
    end

    test "a commit is undone by moving the branch back; a pushed one is refused with how to revert it", %{id: id, ws: ws} do
      git = fn args -> System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t" | args], cd: ws) end
      git.(~w(init -q -b main))
      git.(~w(commit -q --allow-empty -m base))

      commit = fn n ->
        Xeito.Undo.step(ws, "#{id}/t1/e#{n}", "bash git commit #{n}", fn ->
          File.write!(Path.join(ws, "#{n}.txt"), "#{n}\n")
          git.(~w(add -A))
          git.(["commit", "-q", "-m", "agent #{n}"])
        end)
      end

      commit.(1)
      {base, 0} = git.(~w(rev-parse --short HEAD~1))
      assert {:notice, text} = reply(id, "/undo")
      assert text =~ "main: back to #{String.trim(base)}\n"

      {:notice, _} = reply(id, "/redo")
      {pushed, 0} = git.(~w(rev-parse HEAD))
      git.(["update-ref", "refs/remotes/origin/main", String.trim(pushed)])
      short = String.slice(pushed, 0, 7)

      assert reply(id, "/undo") ==
               {:error,
                "can't undo bash git commit 1: commit #{short} is already pushed; to reverse it, run: git revert #{short}"}
    end

    test "a step that moved HEAD otherwise (a checkout) is left to git", %{id: id, ws: ws} do
      System.cmd("git", ~w(init -q -b main), cd: ws)
      System.cmd("git", ~w(-c user.name=t -c user.email=t@t commit -q --allow-empty -m base), cd: ws)

      Xeito.Undo.step(ws, "#{id}/t1/e1", "bash git checkout -b x", fn ->
        System.cmd("git", ~w(checkout -q -b x), cd: ws)
      end)

      assert reply(id, "/undo") ==
               {:error,
                "can't undo bash git checkout -b x: it moved HEAD (checkout, reset or rebase); undo that with git"}
    end

    test "files outside the workspace that a step named are restored too, or the undo is refused", %{id: id, ws: ws} do
      notes = ws <> "-notes.txt"
      on_exit(fn -> File.rm(notes) end)
      File.write!(notes, "old\n")
      Xeito.Undo.step(ws, "#{id}/t1/e1", "bash sed notes", fn -> File.write!(notes, "new\n") end, outside: [notes])

      assert {:notice, text} = reply(id, "/undo")
      assert text =~ "outside the workspace: #{notes}\n"
      assert File.read!(notes) == "old\n"

      {:notice, _} = reply(id, "/redo")
      File.write!(notes, "mine\n")

      assert reply(id, "/undo") ==
               {:error, "can't undo bash sed notes: #{notes} changed since; nothing was undone"}
    end

    test "steps of another session are not this session's to undo", %{id: id, ws: ws} do
      agent_step(ws, "ses-other/t1/e1", "a.txt", "a\n")
      assert reply(id, "/undo") == {:error, "nothing to undo"}
    end
  end

  test "commands/0: the daemon's commands, each explained by /help", %{id: id} do
    assert {:notice, help} = reply(id, "/help")
    assert "halt" in Session.commands()
    for name <- Session.commands(), do: assert(help =~ "/#{name}")
  end

  test "help and machines are notices", %{id: id} do
    assert {:notice, "/" <> _} = reply(id, "/help")
    assert {:notice, text} = reply(id, "/machines")
    assert text =~ "run_tests"
  end

  test "unknown commands, machines and skills are errors", %{id: id} do
    assert {:error, "unknown command /frobnicate; try /help"} = reply(id, "/frobnicate")
    assert {:error, "/run <command>: a shell command to run in the workspace"} = reply(id, "/run")
    assert {:error, "unknown machine \"nope\"; available: " <> _} = reply(id, "/machine nope")
    assert {:error, "no skill named \"nope\""} = reply(id, "/skill:nope")
  end

  describe "/run <command>" do
    test "runs a shell command; its output joins the conversation for the next turn", %{id: id} do
      :ok = Session.prompt(id, "/run echo hello")

      assert_receive {:xeito, _, %{type: "run_selected", attrs: %{"machine" => "Xeito.Machines.Shell"}}}, 2_000

      assert_receive {:xeito, _, %{type: "turn_finished", attrs: %{"status" => :done, "answer" => answer}}}, 5_000
      assert answer == "`echo hello` exited 0"

      assert [%{role: "user", content: note}] = Session.history(id)
      assert note == "(I ran `echo hello` in the workspace:\n```\nexit status 0\nhello\n```)"
    end

    test "a failing command ends the turn failed, and says so", %{id: id} do
      :ok = Session.prompt(id, "/run echo nope >&2; exit 3")

      assert_receive {:xeito, _, %{type: "turn_finished", attrs: %{"status" => :failed, "answer" => answer}}}, 5_000
      assert answer == "`echo nope >&2; exit 3` exited 3"

      assert [%{content: "(I ran `echo nope >&2; exit 3` in the workspace:\n```\nexit status 3\nnope\n```)"}] =
               Session.history(id)
    end

    test "a halted command leaves a note that it did not finish", %{id: id} do
      :ok = Session.prompt(id, "/run sleep 5")
      assert_receive {:xeito, _, %{type: "effect_requested"}}, 2_000
      :ok = Session.prompt(id, "/halt")
      assert_receive {:xeito, _, %{type: "turn_finished", attrs: %{"status" => :halted}}}, 2_000

      assert [%{role: "user", content: "(I ran `sleep 5` in the workspace and stopped it before it finished.)"}] =
               Session.history(id)
    end

    test "a rebuilt session has the same note", %{id: id, log: log, ws: ws} do
      :ok = Session.prompt(id, "/run echo again")
      assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
      history = Session.history(id)

      [{pid, _}] = Registry.lookup(Xeito.SessionRegistry, id)
      DynamicSupervisor.terminate_child(Xeito.SessionSupervisor, pid)
      {:ok, ^id} = Session.start(cwd: ws, log: log, id: id)

      assert Session.history(id) == history
    end

    test "/machine shell <command> is the same machine", %{id: id} do
      :ok = Session.prompt(id, "/machine shell echo hi")
      assert_receive {:xeito, _, %{type: "turn_finished", attrs: %{"answer" => "`echo hi` exited 0"}}}, 5_000
    end
  end

  test "a review answer with nothing waiting is an error", %{id: id} do
    assert {:error, "nothing is waiting for approved"} = reply(id, "/approve")
    assert {:error, "nothing is waiting for denied"} = reply(id, "/deny")
  end

  test "the off-box budget takes a non-negative amount", %{id: id} do
    assert {:notice, "off-box budget per run: $0.5"} = reply(id, "/budget 0.5")
    assert {:error, "usage: /budget <usd>"} = reply(id, "/budget lots")
    assert {:error, "usage: /budget <usd>"} = reply(id, "/budget -1")
  end

  test "step mode and breakpoints", %{id: id} do
    assert {:notice, "step mode on"} = reply(id, "/step")
    assert {:notice, "step mode off"} = reply(id, "/step")
    assert {:notice, "step mode on"} = reply(id, "/step")
    assert {:notice, "step mode off"} = reply(id, "/continue")
    assert {:notice, "step mode off · breakpoints: {:state, :verifying}"} = reply(id, "/break state:verifying")
    assert {:error, "breakpoints: " <> _} = reply(id, "/break sideways")
    assert {:notice, "step mode off"} = reply(id, "/break clear")
  end

  test "/halt with nothing running is an error", %{id: id} do
    assert {:error, "nothing is running"} = reply(id, "/halt")
  end

  test "/halt stops a running command; the turn ends halted", %{id: id} do
    :ok = Session.prompt(id, "/run sleep 5")
    assert_receive {:xeito, _, %{type: "effect_requested"}}, 2_000

    :ok = Session.prompt(id, "/halt")
    assert_receive {:xeito, _, %{type: "turn_finished", attrs: %{"status" => :halted}}}, 2_000
    assert {:error, "nothing is running"} = reply(id, "/halt")
  end

  test "/halt stops the command and the processes it started", %{id: id, ws: ws} do
    :ok = Session.prompt(id, "/run sleep 30 & echo $! > child.pid; wait")
    path = Path.join(ws, "child.pid")
    eventually(fn -> File.exists?(path) and File.read!(path) =~ ~r/\d+\n/ end)
    child = path |> File.read!() |> String.trim()

    :ok = Session.prompt(id, "/halt")
    assert_receive {:xeito, _, %{type: "turn_finished", attrs: %{"status" => :halted}}}, 2_000
    eventually(fn -> not match?({_, 0}, System.cmd("kill", ["-0", child], stderr_to_stdout: true)) end, 5_000)
  end

  test "stepping needs a paused run", %{id: id} do
    assert {:error, "no run is paused"} = reply(id, "/next")
    assert {:error, "no run is paused"} = reply(id, "/decide safe")
  end

  test "a paused run steps on /next, and /decide takes only existing values", %{id: id} do
    # /run true has one effect, the test command: held, then released.
    assert {:notice, "step mode on"} = reply(id, "/step")
    :ok = Session.prompt(id, "/run true")
    assert_receive {:xeito, _, %{type: "paused"}}, 5_000

    assert {:error, "cannot step: invalid_value"} =
             reply(id, "/decide no_such_value_#{System.unique_integer([:positive])}")

    assert {:error, "cannot step: not_a_decision"} = reply(id, "/decide safe")

    :ok = Session.prompt(id, "/next")
    assert_receive {:xeito, _, %{type: "turn_finished", attrs: %{"status" => :done}}}, 5_000
    assert {:error, "no run is paused"} = reply(id, "/next")
  end

  describe "settled/1: a halted turn's messages, without unanswered tool calls" do
    defp calls(n), do: %{role: "assistant", content: "", tool_calls: List.duplicate(%{name: "bash"}, n)}
    defp tool, do: %{role: "tool", content: "ok"}

    test "complete exchanges are kept" do
      done = [%{role: "user", content: "p"}, calls(2), tool(), tool(), %{role: "assistant", content: "a"}]
      assert Session.settled(done) == done
      assert Session.settled([%{role: "user", content: "p"}]) == [%{role: "user", content: "p"}]
    end

    test "the last calls, if not all answered, are dropped with their partial results" do
      before = [%{role: "user", content: "p"}, calls(1), tool()]
      assert Session.settled(before ++ [calls(2), tool()]) == before
      assert Session.settled(before ++ [calls(1)]) == before
    end
  end

  test "/why lists the decisions of the session's runs, with their confidence", %{id: id, log: log} do
    assert {:notice, "no decisions yet"} = reply(id, "/why")

    for {confidence, n} <- Enum.with_index([0.912, nil, "high"]) do
      attrs = %{
        "decision_type" => "Xeito.Decisions.Risk",
        "value" => :safe,
        "actor" => :rule,
        "model" => "rules",
        "latency_ms" => 1,
        "confidence" => confidence
      }

      decision = %Xeito.Decision{type: Risk, value: :safe, actor: :rule, model: "rules"}

      {:ok, _} =
        Xeito.Log.append(log, "#{id}/t#{n}", [
          Xeito.Log.Event.new("decision_made", {:decision_made, "#{id}/t#{n}/e1", decision}, attrs)
        ])
    end

    assert {:notice, text} = reply(id, "/why")
    assert text =~ "Risk: safe by rule (0.91, rules, 1 ms)"
    assert text =~ "Risk: safe by rule (-, rules, 1 ms)"
    assert text =~ "Risk: safe by rule (high, rules, 1 ms)"
  end

  test "/skill:<name> runs a skill of the workspace in a chat turn", %{id: id, ws: ws} do
    File.mkdir_p!(Path.join(ws, ".agents/skills/greet"))

    File.write!(
      Path.join(ws, ".agents/skills/greet/SKILL.md"),
      "---\nname: greet\ndescription: Greet the user politely.\n---\nSay hello.\n"
    )

    :ok = Session.prompt(id, "/skill:greet")

    assert_receive {:xeito, _,
                    %{type: "run_selected", attrs: %{"machine" => "Xeito.Machines.Chat", "reason" => "/skill:greet"}}},
                   2_000
  end

  test "/machine starts any registered machine with the input it needs", %{id: id} do
    for name <- ~w(check commit fix_failing_test run_tests) do
      :ok = Session.prompt(id, "/machine #{name}")
      assert_receive {:xeito, _, %{type: "run_selected", attrs: %{"reason" => "/machine"}}}, 2_000
      :ok = Session.prompt(id, "/halt")
      assert_receive {:xeito, _, %{type: "turn_finished"}}, 5_000
    end
  end

  test "a session's step limit goes into its chat turns", %{ws: ws} do
    log = start_log!()
    {:ok, id} = Session.start(cwd: ws, log: log, id: "ses-max-#{System.unique_integer([:positive])}", max_steps: 3)
    Session.subscribe(id)
    :ok = Session.prompt(id, "/machine chat")
    assert_receive {:xeito, _, %{type: "run_started", run: run}}, 2_000
    assert [{_, "run_started", {:run_started, _, _, %{max_steps: 3}}} | _] = Xeito.Log.read_run(log, run)
  end

  test "breakpoint specs: a state, a decision type, a confidence; anything else is refused" do
    assert {:ok, {:state, :verifying}} = Session.parse_breakpoint("state:verifying")
    assert {:ok, {:decision, Risk}} = Session.parse_breakpoint("decision:risk")
    assert {:ok, {:confidence_below, 0.5}} = Session.parse_breakpoint("conf<0.5")

    for spec <- [
          "state:no_such_state_#{System.unique_integer([:positive])}",
          "decision:nope",
          "conf<high",
          "conf<0.5x",
          "sideways"
        ],
        do: assert(Session.parse_breakpoint(spec) == :error, spec)
  end

  # The session waits on a review, as it would after a run entered `ask_human`.
  defp wait_on(id, waiting) do
    [{pid, _}] = Registry.lookup(Xeito.SessionRegistry, id)
    :sys.replace_state(pid, &%{&1 | waiting: waiting})
  end

  test "an answer for a run that has ended meanwhile is not accepted", %{id: id} do
    wait_on(id, %{run: "ses-gone/t1", call: nil})

    assert Session.approve(id) == {:error, :not_accepted}
    assert {:error, "the waiting run did not accept denied"} = reply(id, "/deny")
  end

  describe "/approve session and /approve always: a command not asked about again" do
    defp bash(command), do: %{"tool" => "bash", "arguments" => %{"command" => command}}

    test "with nothing waiting, or with a scope that is neither", %{id: id} do
      assert {:error, "nothing is waiting for approval"} = reply(id, "/approve session")
      assert {:error, "nothing is waiting for approval"} = reply(id, "/approve always")
      assert {:error, "/approve takes session or always, not \"forever\""} = reply(id, "/approve forever")
      assert Session.approve(id, "session") == {:error, :nothing_to_approve}
      assert Session.approve(id, "forever") == {:error, :unknown_scope}
    end

    test "a review that is not about a shell command cannot be allowed", %{id: id} do
      wait_on(id, %{run: "ses-gone/t1", call: %{"tool" => "review", "summary" => "commit it"}})

      assert {:error, "only a shell command can be allowed; /approve answers this review"} =
               reply(id, "/approve session")

      assert Session.approve(id, "always") == {:error, :not_a_command}
    end

    test "a run that has ended meanwhile is not accepted, and nothing is remembered", %{id: id, ws: ws} do
      wait_on(id, %{run: "ses-gone/t1", call: bash("mix ci")})

      assert {:error, "the waiting run did not accept approved"} = reply(id, "/approve always")
      assert Session.approve(id, "always") == {:error, :not_accepted}
      assert Allowed.always(ws) == []
    end

    # A run waiting in `ask_human` for a command, as the chat machine would after the Risk decision.
    defp reviewing(id, log, command) do
      {:ok, run} = Xeito.RunSupervisor.start_run(Xeito.TestMachines.Reviewing, %{}, run_id: run_id(), log: log)
      wait_on(id, %{run: run, call: bash(command)})
      run
    end

    test "approved for the session: the run goes on, the command is remembered", %{id: id, log: log} do
      run = reviewing(id, log, "mix ci")
      assert reply(id, "/approve session") == {:notice, "approved · `mix ci` is now allowed for this session"}
      await_exit(run)
      assert %{waiting: nil} = Session.status(id)
      assert {:error, "nothing is waiting for approval"} = reply(id, "/approve session")
    end

    test "approved, but the workspace file cannot be written", %{id: id, log: log, ws: ws} do
      File.mkdir_p!(Path.join([ws, ".xeito", "allowed.json"]))

      run = reviewing(id, log, "mix ci")
      assert Session.approve(id, "always") == {:error, {:not_saved, :eisdir}}
      await_exit(run)
      assert %{waiting: nil} = Session.status(id)

      reviewing(id, log, "git push")

      assert {:error, "approved, but .xeito/allowed.json could not be written: :eisdir"} =
               reply(id, "/approve always")
    end

    test "review answers are not kept for Up/Down", %{id: id, log: log, ws: ws} do
      reply(id, "/approve session")
      reply(id, "/approve")
      reply(id, "/why")
      assert Directory.prompts(log, ws) == ["/why"]
    end
  end
end
