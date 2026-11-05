defmodule Xeito.MachinesTest do
  # Chat calls happen in supervised effect tasks, so Req.Test stubs are shared (serial).
  use Xeito.Case, async: false

  alias Xeito.Effects.Local
  alias Xeito.Log
  alias Xeito.Machines.Check
  alias Xeito.Machines.Commit
  alias Xeito.Run
  alias Xeito.RunSupervisor
  alias Xeito.Scripts.Host
  alias Xeito.TestMachines.Scripted

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

  @tag :sandbox
  test "a script's calls run through the runner as children of its effect; its output is the result",
       %{ws: ws} = ctx do
    log = start_log!(ctx)
    File.write!(Path.join(ws, "a.ex"), "defmodule A do\nend\n")
    File.write!(Path.join(ws, "b.ex"), "defmodule B do\n  # TODO: later\nend\n")
    session = run_id()
    on_exit(fn -> Host.stop(session) end)

    code = """
    {:ok, out} = Script.bash("ls *.ex")
    files = String.split(out, "\\n", trim: true)
    todo = Enum.filter(files, fn f -> {:ok, text} = Script.read(f); String.contains?(text, "TODO") end)
    Script.text("checked \#{length(files)} files")
    todo
    """

    {:ok, id} =
      RunSupervisor.start_run(Scripted, %{cwd: ws, code: code},
        run_id: session <> "/t1",
        log: log,
        runner: {Local, []}
      )

    await_exit(id, 30_000)
    assert {:ok, %{status: :done, ctx: %{output: "checked 2 files\n[\"b.ex\"]"}}} = Run.result(log, id)

    requested =
      for {_, "effect_requested", {:effect_requested, effect}} <- Log.read_run(log, id),
          do: {effect.id, effect.kind, effect.args[:cmd] || effect.args[:path]}

    assert requested == [
             {"#{id}/e1", :script, nil},
             {"#{id}/e1/c1", :bash, "ls *.ex"},
             {"#{id}/e1/c2", :read, "a.ex"},
             {"#{id}/e1/c3", :read, "b.ex"}
           ]
  end

  @tag :sandbox
  test "a run killed during a script runs it again fed the logged results, and only the rest runs for real",
       %{ws: ws} = ctx do
    log = start_log!(ctx)
    File.write!(Path.join(ws, "a.ex"), "first\n")
    File.write!(Path.join(ws, "b.ex"), "second\n")
    session = run_id()
    on_exit(fn -> Host.stop(session) end)
    Xeito.Events.subscribe(:all)

    code = ~s|{:ok, a} = Script.read("a.ex"); {:ok, b} = Script.read("b.ex"); String.trim(a <> b)|
    id = session <> "/t1"

    {:ok, ^id} =
      RunSupervisor.start_run(Scripted, %{cwd: ws, code: code},
        run_id: id,
        log: log,
        runner: {Local, []}
      )

    assert_receive {:xeito, ^id, %{type: "effect_completed", attrs: %{"effect_id" => first}}}, 5_000
    assert first == id <> "/e1/c1"
    # What the first run saw is in the log; the file changes before the second run.
    File.write!(Path.join(ws, "a.ex"), "changed\n")
    old_pid = Run.whereis(id)
    Process.exit(old_pid, :kill)

    await_exit(id, 30_000)
    assert {:ok, %{status: :done, ctx: %{output: "first\nsecond"}}} = Run.result(log, id)

    requested = for {_, "effect_requested", {:effect_requested, e}} <- Log.read_run(log, id), do: {e.id, e.args[:path]}
    # a.ex was read once: the recovered script was fed its logged content.
    assert Enum.count(requested, &match?({_, "a.ex"}, &1)) == 1
    assert Enum.any?(Log.read_run(log, id), &match?({_, "run_recovered", _}, &1))
  end

  @tag :sandbox
  test "a script's writes are one undo step, labelled by the script", %{ws: ws} = ctx do
    log = start_log!(ctx)
    session = run_id()
    on_exit(fn -> Host.stop(session) end)
    code = ~s|Script.write("a.txt", "one\\n"); Script.write("b.txt", "two\\n"); Script.bash("echo three > c.txt"); :ok|

    {:ok, id} =
      RunSupervisor.start_run(Scripted, %{cwd: ws, code: code},
        run_id: session <> "/t1",
        log: log,
        runner: {Local, []}
      )

    await_exit(id, 30_000)
    assert {:ok, %{status: :done}} = Run.result(log, id)
    assert File.exists?(Path.join(ws, "c.txt"))

    assert [%{id: ^id <> "/e1", label: "script " <> label}] = Xeito.Undo.steps(ws, session)
    assert label =~ ~s(Script.write("a.txt")
    assert {:ok, _} = Xeito.Undo.undo(ws, session, 1)
    refute File.exists?(Path.join(ws, "a.txt"))
    refute File.exists?(Path.join(ws, "b.txt"))
    refute File.exists?(Path.join(ws, "c.txt"))
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
    cfg = chat_stub(self(), [{"I could not fix it.", []}])
    id = start(Check, %{cwd: ws, check_cmd: "exit 1", max_attempts: 1}, cfg, log)
    eventually(fn -> leaf(id) == :ask_human end)
    Run.send_event(id, :denied, %{}, :human)
    await_exit(id)
    assert {:ok, %{state: :failed}} = Run.result(log, id)
  end

  test "commit: a failed step records its output, its error, or the result itself" do
    assert Commit.record_error(%{}, %{output: "nothing to commit"}).error == "nothing to commit"
    assert Commit.record_error(%{}, %{error: :timeout}).error == :timeout
    assert Commit.record_error(%{}, %{exit_status: 1}).error == "%{exit_status: 1}"
  end
end
