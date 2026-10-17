defmodule Mix.Tasks.Xeito.RunTest do
  # The fake model answers from supervised effect tasks, so the Req.Test stub is shared (serial).
  use Xeito.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Xeito.Run

  setup {Req.Test, :set_req_test_to_shared}

  setup do
    dir = Path.join(System.tmp_dir!(), "xeito-runtask-#{System.unique_integer([:positive])}")
    ws = Path.join(dir, "ws")
    File.mkdir_p!(Path.join(ws, ".agents/skills/greet"))

    File.write!(
      Path.join(ws, ".agents/skills/greet/SKILL.md"),
      "---\nname: greet\ndescription: Greet.\n---\nSay hello.\n"
    )

    on_exit(fn -> File.rm_rf(dir) end)

    me = self()

    Req.Test.stub(:run_task_ollama, fn
      %{request_path: "/api/ps"} = conn ->
        Req.Test.json(conn, %{"models" => [%{"name" => "big", "model" => "big"}]})

      conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:chat_request, JSON.decode!(raw)})

        body =
          Enum.map_join(
            [
              %{"message" => %{"role" => "assistant", "content" => "Hello "}, "done" => false},
              %{"message" => %{"role" => "assistant", "content" => "there."}, "done" => false},
              %{"done" => true, "prompt_eval_count" => 100, "eval_count" => 10}
            ],
            &(JSON.encode!(&1) <> "\n")
          )

        conn |> Plug.Conn.put_resp_content_type("application/x-ndjson") |> Plug.Conn.send_resp(200, body)
    end)

    chat = [url: "http://ollama.test", plug: {Req.Test, :run_task_ollama}, model: "big"]
    log = start_log!()
    socket = Path.join(dir, "x.sock")

    start_supervised!(
      {Xeito.Api,
       socket: socket,
       name: :"api_#{System.unique_integer([:positive])}",
       session: [log: log, chat: chat, decider: [deciders: []]]}
    )

    %{socket: socket, ws: ws, log: log, dir: dir}
  end

  defp run(ctx, args, stdin \\ "") do
    args = ["--socket", ctx.socket, "--cwd", ctx.ws | args]
    err = capture_io(:stderr, fn -> send(self(), {:stdout, capture_io(stdin, fn -> exit_code(args) end)}) end)
    assert_received {:stdout, out}
    {out, err}
  end

  # The exit code goes to the mailbox: `{:exit, code}`.
  defp exit_code(args) do
    Run.run(args)
    send(self(), {:exit, 0})
  catch
    :exit, {:shutdown, code} -> send(self(), {:exit, code})
  end

  test "text on stdin through a skill: the finished answer alone on stdout, the model without tools", ctx do
    assert run(ctx, ["--skill", "greet"], "to Ana\n") == {"Hello there.\n", ""}

    assert_received {:chat_request, %{"messages" => messages} = request}
    assert List.last(messages)["content"] =~ "Say hello.\n\nRequest: to Ana"
    assert request["tools"] in [nil, []]
  end

  test "--json: the events, then the result with the run, which is in the workspace log", ctx do
    {out, ""} = run(ctx, ["--json", "hi"])
    lines = out |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert %{"event" => "result", "status" => "done", "answer" => "Hello there.", "run" => run, "tokens_in" => 100} =
             List.last(lines)

    assert Enum.any?(lines, &(&1["event"] == "delta"))
    assert {_, "run_finished", _} = ctx.log |> Xeito.Log.read_run(run) |> List.last()

    # The session it started is closed once the answer is in.
    [session, _turn] = String.split(run, "/")
    eventually(fn -> Registry.lookup(Xeito.SessionRegistry, session) == [] end)
  end

  test "-s streams the same text; -o also writes it to a file", ctx do
    file = Path.join(ctx.dir, "answer.txt")
    assert run(ctx, ["-s", "-o", file, "hi"]) == {"Hello there.\n", ""}
    assert File.read!(file) == "Hello there.\n"
  end

  test "a machine by name: its commands on stderr, its answer on stdout", ctx do
    {out, err} = run(ctx, ["--machine", "shell", "echo hi"])
    assert err =~ "$ echo hi"
    assert out =~ "hi"
  end

  test "--as: the model's call is constrained to the type; an answer that is not JSON fails", ctx do
    assert run(ctx, ["--as", "triage", "the test fails"]) == {"", "✗ the answer is not JSON\n"}
    assert_received {:exit, 1}
    assert_received {:chat_request, %{"format" => %{"properties" => %{"value" => %{"enum" => ["flaky" | _]}}}}}
  end

  test "--as FILE: a JSON Schema file", ctx do
    file = Path.join(ctx.dir, "schema.json")
    File.write!(file, ~s({"type": "object"}))
    run(ctx, ["--as", file, "a talk"])
    assert_received {:chat_request, %{"format" => %{"type" => "object"}}}

    File.write!(file, "not json")
    assert_raise Mix.Error, "--as: the file is not JSON", fn -> run(ctx, ["--as", file, "a talk"]) end
  end

  test "--dry-run prints the request and calls no model", ctx do
    {out, ""} = run(ctx, ["--dry-run", "--skill", "greet", "to Ana"])
    assert out =~ ~r/\A── tier local · model big · tools: none\n── system\n/
    assert out =~ "── user\nUse the skill \"greet\""
    refute_received {:chat_request, _}
  end

  test "--list and --print-skill read the workspace's skills, without a daemon", ctx do
    {out, ""} = run(%{ctx | socket: "/nonexistent/x.sock"}, ["--list"])
    assert out =~ ~r/^greet\s+project\s+Greet\.$/m

    {out, ""} = run(%{ctx | socket: "/nonexistent/x.sock"}, ["--print-skill", "greet"])
    assert out == "---\nname: greet\ndescription: Greet.\n---\nSay hello.\n"
    assert_raise Mix.Error, "no skill named \"nope\"", fn -> run(ctx, ["--print-skill", "nope"]) end
  end

  test "what the daemon refuses, or a bad option, is an error before anything is sent", ctx do
    assert_raise Mix.Error, "no skill named \"nope\"", fn -> run(ctx, ["--skill", "nope", "x"]) end
    assert_raise Mix.Error, "unknown option --fly", fn -> run(ctx, ["--fly"]) end
    assert_raise Mix.Error, ~r/^unknown tool "fly"/, fn -> run(ctx, ["--tools=fly", "x"]) end
    assert_raise Mix.Error, ~r/^nothing to send/, fn -> run(ctx, []) end
  end

  test "no daemon at the socket is an error" do
    assert_raise Mix.Error, ~r/^no daemon at \/nonexistent/, fn ->
      capture_io("", fn -> Run.run(["--socket", "/nonexistent/x.sock", "x"]) end)
    end
  end

  test "--help shows the documentation and runs nothing" do
    assert capture_io(fn -> Run.run(["--help"]) end) =~ "mix xeito.run"
  end
end
