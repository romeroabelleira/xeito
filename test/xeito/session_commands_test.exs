defmodule Xeito.SessionCommandsTest do
  use Xeito.Case, async: false

  alias Xeito.Decisions.Risk
  alias Xeito.Session

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

  test "help and machines are notices", %{id: id} do
    assert {:notice, "/" <> _} = reply(id, "/help")
    assert {:notice, text} = reply(id, "/machines")
    assert text =~ "run_tests"
  end

  test "unknown commands, machines and skills are errors", %{id: id} do
    assert {:error, "unknown command /frobnicate; try /help"} = reply(id, "/frobnicate")
    assert {:error, "unknown command /run; try /help"} = reply(id, "/run")
    assert {:error, "unknown machine \"nope\"; available: " <> _} = reply(id, "/machine nope")
    assert {:error, "no skill named \"nope\""} = reply(id, "/skill:nope")
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

  test "an answer for a run that has ended meanwhile is not accepted", %{id: id} do
    [{pid, _}] = Registry.lookup(Xeito.SessionRegistry, id)
    :sys.replace_state(pid, &%{&1 | waiting: %{run: "ses-gone/t1", call: nil}})

    assert Session.approve(id) == {:error, :not_accepted}
    assert {:error, "the waiting run did not accept denied"} = reply(id, "/deny")
  end
end
