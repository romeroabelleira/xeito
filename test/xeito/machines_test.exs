defmodule Xeito.MachinesTest do
  # Chat calls happen in supervised effect tasks, so Req.Test stubs are shared (serial).
  use Xeito.Case, async: false

  alias Xeito.Effects.Local
  alias Xeito.Machines.Chat
  alias Xeito.Machines.Check
  alias Xeito.Machines.Commit
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Machines.RunTests
  alias Xeito.Run
  alias Xeito.RunSupervisor
  alias Xeito.Session.Router

  @moduletag :tmp_dir

  setup {Req.Test, :set_req_test_to_shared}

  setup %{tmp_dir: dir} do
    ws = Path.join(dir, "ws")
    File.mkdir_p!(ws)
    %{ws: ws}
  end

  # A streaming chat stub answering the scripted turns in order.
  defp chat_stub(test_pid, turns) do
    {:ok, script} = Agent.start_link(fn -> turns end)

    Req.Test.stub(:machines_chat, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:chat_request, JSON.decode!(raw)})
      {content, calls} = Agent.get_and_update(script, fn [t | rest] -> {t, rest} end)

      message = assistant(content, calls)

      body =
        Enum.map_join(
          [%{"message" => message, "done" => false}, %{"done" => true, "prompt_eval_count" => 10, "eval_count" => 5}],
          "\n",
          &JSON.encode!/1
        )

      Plug.Conn.send_resp(conn, 200, body <> "\n")
    end)

    [url: "http://chat.test", plug: {Req.Test, :machines_chat}, model: "big"]
  end

  defp assistant(content, []), do: %{"role" => "assistant", "content" => content}

  # --- skills --------------------------------------------------------------------------------
  defp assistant(content, calls) do
    tool_calls = for {n, a} <- calls, do: %{"function" => %{"name" => n, "arguments" => a}}
    Map.put(assistant(content, []), "tool_calls", tool_calls)
  end

  defp start(machine, input, cfg, log, extra \\ []) do
    runner = {Local, [chat: cfg, decide: &safe_and_no_skill/1] ++ extra}

    {:ok, id} =
      RunSupervisor.start_run(machine, input, run_id: run_id(), log: log, runner: runner)

    id
  end

  # Every command is safe, and no skill is suggested (a chat turn decides one first).
  defp safe_and_no_skill(%{args: %{decision: Xeito.Decisions.Skill}}), do: :none
  defp safe_and_no_skill(_effect), do: :safe

  defp leaf(id), do: Run.whereis(id) && Run.snapshot(id).leaf

  defp git!(ws, args), do: {_, 0} = System.cmd("git", args, cd: ws, stderr_to_stdout: true)

  defp repo!(ws) do
    git!(ws, ~w(init -q))
    git!(ws, ~w(config user.email t@example.com))
    git!(ws, ~w(config user.name Test))
    File.write!(Path.join(ws, "a.txt"), "one\n")
    git!(ws, ~w(add -A))
    git!(ws, ~w(commit -q -m init))
  end

  test "commit drafts a message, waits for approval, and commits", %{ws: ws} = ctx do
    log = start_log!(ctx)
    repo!(ws)
    File.write!(Path.join(ws, "a.txt"), "two\n")
    cfg = chat_stub(self(), [{"```\nUpdate a.txt to two\n\n- replace one with two\n```", []}])

    id = start(Commit, %{cwd: ws, request: "commit this"}, cfg, log)
    eventually(fn -> leaf(id) == :ask_human end)
    assert %{review: "commit 1 file: Update a.txt to two"} = Run.snapshot(id).ctx

    assert_received {:chat_request, req}
    assert req["tools"] == [] and List.last(req["messages"])["content"] =~ "+two"

    Run.send_event(id, :approved, %{}, :human)
    await_exit(id)
    assert {:ok, %{state: :done, ctx: %{answer: "Committed " <> _}}} = Run.result(log, id)
    {log_text, 0} = System.cmd("git", ~w(log -1 --format=%B), cd: ws)
    assert log_text =~ "Update a.txt to two\n\n- replace one with two"
  end

  test "commit with nothing to commit is done; denied, it is cancelled", %{ws: ws} = ctx do
    log = start_log!(ctx)
    repo!(ws)
    id = start(Commit, %{cwd: ws}, chat_stub(self(), []), log)
    await_exit(id)
    assert {:ok, %{state: :done, ctx: %{answer: "Nothing to commit."}}} = Run.result(log, id)

    File.write!(Path.join(ws, "b.txt"), "new\n")
    id = start(Commit, %{cwd: ws}, chat_stub(self(), [{"Add b.txt", []}]), log)
    # --- check -----------------------------------------------------------------------------------
    eventually(fn -> leaf(id) == :ask_human end)
    Run.send_event(id, :denied, %{}, :human)
    await_exit(id)
    assert {:ok, %{state: :cancelled}} = Run.result(log, id)
    {count, 0} = System.cmd("git", ~w(rev-list --count HEAD), cd: ws)
    assert String.trim(count) == "1"
  end

  test "check hands a failure to a chat run and passes after the fix", %{ws: ws} = ctx do
    log = start_log!(ctx)
    File.write!(Path.join(ws, "style.txt"), "bad\n")
    edit = {"edit", %{"path" => "style.txt", "old_text" => "bad", "new_text" => "good"}}
    cfg = chat_stub(self(), [{"", [edit]}, {"Fixed the style.", []}])

    id =
      start(
        Check,
        %{cwd: ws, check_cmd: "grep -q good style.txt || (echo 'style: bad'; exit 1)"},
        cfg,
        log
      )

    await_exit(id)

    assert {:ok, %{state: :done, ctx: %{answer: "Checks pass after 1 fix run(s)."}}} =
             Run.result(log, id)

    assert_received {:chat_request, first}
    assert List.last(first["messages"])["content"] =~ "style: bad"
  end

  test "check asks a human when the attempts are used up", %{ws: ws} = ctx do
    log = start_log!(ctx)
    # --- routing and intent rules ------------------------------------------------------------
    cfg = chat_stub(self(), [{"I could not fix it.", []}])
    id = start(Check, %{cwd: ws, check_cmd: "exit 1", max_attempts: 1}, cfg, log)
    eventually(fn -> leaf(id) == :ask_human end)
    Run.send_event(id, :denied, %{}, :human)
    await_exit(id)
    assert {:ok, %{state: :failed}} = Run.result(log, id)
  end

  test "routing rules pick the structured machines", %{ws: ws} do
    assert {FixFailingTest, _} = Router.route(:edit, "the login test is red")
    assert {Commit, _} = Router.route(:run, "commit my changes")
    assert {Check, _} = Router.route(:edit, "fix the credo warnings")
    assert {Check, _} = Router.route(:run, "run the linter")
    assert {RunTests, _} = Router.route(:run, "run the tests")
    assert {Chat, _} = Router.route(:question, "what does commit abc123 change?")

    # Writing a test, even one meant to fail first, is not fixing one.
    assert {Chat, _} = Router.route(:edit, "Write the failing test in tui_test.exs for banner/1.")
    assert {Chat, _} = Router.route(:edit, "add a red test for the parser, then make it pass")
    assert {Chat, _} = Router.route(:edit, "Develop the broken-link detector test-first")
    assert {FixFailingTest, _} = Router.route(:edit, "the checkout test fails, fix it")

    assert Router.check_command(ws) == "make test"
    assert Router.quick_check_command(ws) == nil
    File.write!(Path.join(ws, "Cargo.toml"), "")
    assert Router.quick_check_command(ws) == "cargo check"
    File.write!(Path.join(ws, "mix.exs"), "defp aliases, do: [ci: [\"test\"]]")
    assert Router.check_command(ws) == "mix ci"

    assert Router.quick_check_command(ws) ==
             "mix format --check-formatted && mix compile --warnings-as-errors"

    File.write!(Path.join(ws, "mix.exs"), ~s(defp aliases, do: ["check.quick": ["compile"]]))
    assert Router.quick_check_command(ws) == "mix check.quick"
  end

  test "commit: a failed step records its output, its error, or the result itself" do
    assert Commit.record_error(%{}, %{output: "nothing to commit"}).error == "nothing to commit"
    assert Commit.record_error(%{}, %{error: :timeout}).error == :timeout
    assert Commit.record_error(%{}, %{exit_status: 1}).error == "%{exit_status: 1}"
  end
end
