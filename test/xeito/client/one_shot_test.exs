defmodule Xeito.Client.OneShotTest do
  use ExUnit.Case, async: true

  alias Xeito.Client.OneShot

  defp parse!(args) do
    {:ok, opts} = OneShot.parse(args)
    opts
  end

  describe "parse/1" do
    test "defaults: no skill or machine, tools off, streaming left to the terminal" do
      assert %{skill: nil, machine: nil, tools: false, stream: nil, json: false, extract: nil, yes: false, words: []} =
               parse!([])
    end

    test "flags and the words of the request" do
      opts = parse!(~w(--skill summarize -s -o out.md --extract-last --yes --cwd w two words))
      assert %{skill: "summarize", stream: true, out: "out.md", extract: :last, yes: true} = opts
      assert %{cwd: "w", words: ["two", "words"]} = opts
      assert %{stream: false, extract: :all, json: true} = parse!(~w(--no-stream --extract --json))
      assert %{machine: "run_tests", continue: true} = parse!(~w(--machine run_tests --continue))
      assert %{session: "ses-1", socket: "/s"} = parse!(~w(--session ses-1 --socket /s))
    end

    test "--tools alone allows all of them, --tools=LIST those listed" do
      assert %{tools: true, words: ["text"]} = parse!(~w(--tools text))
      assert %{tools: ["read", "bash"]} = parse!(~w(--tools=read,bash))
    end

    test "refuses unknown options and choices that exclude each other" do
      assert {:error, "unknown option --fly"} = OneShot.parse(~w(--fly))
      assert {:error, "--skill or --machine, not both"} = OneShot.parse(~w(--skill a --machine chat))
      assert {:error, "--continue or --session, not both"} = OneShot.parse(~w(--continue --session s))
      assert {:error, "--extract or --extract-last, not both"} = OneShot.parse(~w(--extract --extract-last))
    end
  end

  test "text/2: the words, then what came on stdin; nothing is an error" do
    assert OneShot.text(["fix", "this"], :eof) == {:ok, "fix this"}
    assert OneShot.text([], "some input\n") == {:ok, "some input\n"}
    assert OneShot.text(["summarize:"], "body\n") == {:ok, "summarize:\n\nbody\n"}
    assert OneShot.text([], "  \n") == {:error, "nothing to send: give the text as arguments or on stdin"}
    assert OneShot.text([], :eof) == {:error, "nothing to send: give the text as arguments or on stdin"}
    # A machine such as run_tests needs no text.
    assert OneShot.text([], :eof, %{machine: "run_tests"}) == {:ok, ""}
  end

  test "requests: a fresh session, the directory's last, or a given one; the prompt with the turn's choices" do
    cwd = Path.expand("w")
    assert OneShot.open_request(parse!(~w(--cwd w))) == %{"cmd" => "start", "cwd" => cwd}
    assert OneShot.open_request(parse!(~w(--cwd w --continue))) == %{"cmd" => "open", "cwd" => cwd}

    assert OneShot.open_request(parse!(~w(--cwd w --session ses-1))) ==
             %{"cmd" => "attach", "session" => "ses-1", "cwd" => cwd}

    assert OneShot.prompt_request("ses-1", "hi", parse!(~w(--skill a --tools=read))) ==
             %{"cmd" => "prompt", "session" => "ses-1", "text" => "hi", "skill" => "a", "tools" => ["read"]}

    assert OneShot.prompt_request("ses-1", "hi", parse!([])) ==
             %{"cmd" => "prompt", "session" => "ses-1", "text" => "hi", "tools" => false}
  end

  test "stream?/2: as asked, else when stdout is a terminal; never for extracts or JSON" do
    assert OneShot.stream?(parse!([]), true)
    refute OneShot.stream?(parse!([]), false)
    assert OneShot.stream?(parse!(~w(-s)), false)
    refute OneShot.stream?(parse!(~w(--no-stream)), true)
    refute OneShot.stream?(parse!(~w(-s --extract)), true)
    refute OneShot.stream?(parse!(~w(-s --json)), true)
  end

  test "extract/2: the fenced code blocks of an answer, or only the last" do
    answer = "Here:\n```elixir\na = 1\n```\nand\n~~~\nb\n~~~\n```sh\nc\nd\n```\n"
    assert OneShot.extract(answer, :all) == "a = 1\nb\nc\nd\n"
    assert OneShot.extract(answer, :last) == "c\nd\n"
    assert OneShot.extract("no code", :all) == ""
    assert OneShot.extract("no code", :last) == ""
  end

  describe "event/2: what each daemon event does" do
    defp events(opts, events, tty \\ false) do
      {actions, _} =
        Enum.flat_map_reduce(events, OneShot.new(opts, tty), fn e, acc -> OneShot.event(acc, e) end)

      actions
    end

    defp out(actions), do: for({:stdout, text} <- actions, into: "", do: IO.iodata_to_binary(text))
    defp err(actions), do: for({:stderr, text} <- actions, into: "", do: IO.iodata_to_binary(text))

    @run "ses-1/t1"
    defp selected, do: %{"event" => "run_selected", "run" => @run, "attrs" => %{"machine" => "Chat"}}
    defp delta(text, run \\ @run), do: %{"event" => "delta", "run" => run, "attrs" => %{"text" => text}}

    defp finished(answer, status \\ "done"),
      do: %{
        "event" => "turn_finished",
        "run" => @run,
        "attrs" => %{"status" => status, "final_state" => "answered", "answer" => answer}
      }

    test "not streaming: only the finished answer on stdout, with a final newline, and exit 0" do
      actions = events(parse!([]), [selected(), delta("Hel"), delta("lo"), finished("Hello")])
      assert out(actions) == "Hello\n"
      assert err(actions) == ""
      assert List.last(actions) == {:done, 0}
    end

    test "streaming: the turn's own deltas as they come, then a newline; nothing printed twice" do
      actions =
        events(parse!(~w(-s)), [selected(), delta("Hel"), delta("x", "#{@run}/e1/run"), delta("lo"), finished("Hello")])

      assert out(actions) == "Hello\n"
      assert [{:stdout, "Hel"}, {:stdout, "lo"} | _] = Enum.filter(actions, &match?({:stdout, _}, &1))
    end

    test "streaming an answer that ends in a newline adds none; a turn that streamed nothing prints its answer" do
      assert out(events(parse!(~w(-s)), [selected(), delta("Hi\n"), finished("Hi\n")])) == "Hi\n"
      assert out(events(parse!(~w(-s)), [selected(), finished("3 tests, 0 failures")])) == "3 tests, 0 failures\n"
    end

    test "an empty answer prints nothing" do
      assert out(events(parse!([]), [selected(), finished("")])) == ""
      assert out(events(parse!([]), [selected(), finished(nil)])) == ""
    end

    test "--extract prints the code blocks, and -o writes what is printed to the file" do
      actions = events(parse!(~w(--extract -o f.txt)), [selected(), finished("x\n```\ncode\n```\n")])
      assert out(actions) == "code\n"
      assert {:write, "f.txt", "code\n"} in actions
    end

    test "a turn that did not finish normally exits 1 and says why on stderr" do
      actions = events(parse!([]), [selected(), finished("Stopped.", "failed")])
      assert err(actions) =~ "✗ answered"
      assert out(actions) == "Stopped.\n"
      assert List.last(actions) == {:done, 1}
    end

    test "notices, errors and tool calls go to stderr" do
      bash = %{"event" => "effect_requested", "run" => @run, "attrs" => %{"kind" => "bash", "args" => %{"cmd" => "ls"}}}
      chat = %{"event" => "effect_completed", "run" => @run, "attrs" => %{"kind" => "chat", "result" => %{}}}
      notice = %{"event" => "notice", "attrs" => %{"text" => "· a notice"}}
      intent = %{"event" => "intent", "attrs" => %{"value" => "explain", "actor" => "rule", "confidence" => 1.0}}

      actions = events(parse!([]), [notice, selected(), intent, bash, chat])
      assert err(actions) == "· a notice\n  $ ls\n"
      assert out(actions) == ""
    end

    test "an error before the turn's run starts ends the call with exit 1" do
      error = %{"event" => "error", "attrs" => %{"text" => "could not start Chat"}}
      assert [{:stderr, "✗ could not start Chat\n"}, {:done, 1}] = events(parse!([]), [error])
    end

    test "a review is denied, as no one is there to answer it; --yes approves" do
      review = %{"event" => "human_needed", "run" => @run, "attrs" => %{"call" => %{"summary" => "run rm"}}}
      assert [{:stderr, deny_note}, {:request, %{"cmd" => "deny"}}] = events(parse!([]), [selected(), review])
      assert deny_note =~ "denied: run rm (--yes approves)"
      assert [{:stderr, _}, {:request, %{"cmd" => "approve"}}] = events(parse!(~w(--yes)), [selected(), review])

      notes =
        for call <- [%{"tool" => "bash", "arguments" => %{"command" => "rm x"}}, %{"tool" => "write"}, nil] do
          [{:stderr, note}, _] = events(parse!(~w(--yes)), [selected(), put_in(review["attrs"]["call"], call)])
          note
        end

      assert notes == ["· approved: run `rm x`\n", "· approved: write\n", "· approved: the step\n"]
    end

    test "a lost daemon ends the call with exit 1" do
      assert [{:stderr, "daemon disconnected\n"}, {:done, 1}] =
               events(parse!([]), [%{"event" => "disconnected"}])
    end

    test "--json: every event as a JSON line, then the result with answer, tier, tokens and cost" do
      chat = %{
        "event" => "effect_completed",
        "run" => @run,
        "attrs" => %{
          "kind" => "chat",
          "result" => %{"model" => "m1", "tokens_in" => 100, "tokens_out" => 10, "usd" => 0.5}
        }
      }

      workspace = %{"event" => "workspace", "attrs" => %{"chat" => %{"tier" => "local"}}}
      actions = events(parse!(~w(--json)), [selected(), delta("Hi"), chat, workspace, finished("Hi")])
      lines = actions |> out() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

      assert [%{"event" => "run_selected"}, %{"event" => "delta"}, %{"event" => "effect_completed"}, _, _, result] = lines

      assert result == %{
               "event" => "result",
               "run" => @run,
               "status" => "done",
               "answer" => "Hi",
               "tier" => "local",
               "model" => "m1",
               "tokens_in" => 100,
               "tokens_out" => 10,
               "usd" => 0.5
             }

      assert err(actions) == ""
    end
  end
end
