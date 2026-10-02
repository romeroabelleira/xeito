defmodule Xeito.SessionCommandsTest do
  use Xeito.Case, async: false

  alias Xeito.Session

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-cmd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    {:ok, id} = Session.start(cwd: ws, log: start_log!(), id: "ses-cmd-#{System.unique_integer([:positive])}")
    Session.subscribe(id)
    %{id: id}
  end

  # The text of the next notice or error the session emits.
  defp reply(id, command) do
    :ok = Session.prompt(id, command)
    assert_receive {:xeito, _, %{type: type, attrs: %{"text" => text}}} when type in ["notice", "error"], 2_000
    {String.to_atom(type), text}
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
end
