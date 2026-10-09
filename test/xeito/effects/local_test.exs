defmodule Xeito.Effects.LocalTest do
  use ExUnit.Case, async: true

  alias Xeito.Effect
  alias Xeito.Effects.Local

  setup do
    dir = Path.join(System.tmp_dir!(), "xeito-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{ws: dir}
  end

  test "bash runs in the workspace and reports the exit status", %{ws: ws} do
    assert %{exit_status: 0, output: output} = Local.run(Effect.bash("pwd", cwd: ws), [])
    # `pwd` prints the physical path; on macOS the temp directory is behind a symlink (/var -> /private/var).
    {physical, 0} = System.cmd("pwd", ["-P"], cd: ws)
    assert String.trim(output) == String.trim(physical)
    assert %{exit_status: 3} = result = Local.run(Effect.bash("exit 3", cwd: ws), [])
    refute Map.has_key?(result, :timed_out)
  end

  test "bash times out, with the output so far and how long it was given", %{ws: ws} do
    assert %{exit_status: 124, output: output, timed_out: true} =
             Local.run(Effect.bash("echo started; sleep 5", cwd: ws, timeout: 200), [])

    assert output == "started\n[timed out after 200 ms; the command and its children were stopped]\n"
  end

  test "write and read stay inside the workspace", %{ws: ws} do
    assert %{ok: true} = Local.run(Effect.write("sub/a.txt", "hello", cwd: ws), [])
    assert %{ok: true, content: "hello"} = Local.run(Effect.read("sub/a.txt", cwd: ws), [])

    assert %{ok: false, error: :outside_workspace} =
             Local.run(Effect.read("../../etc/passwd", cwd: ws), [])

    assert %{ok: false, error: :outside_workspace} =
             Local.run(Effect.write("/tmp/x", "no", cwd: ws), [])
  end

  describe "undo: write, edit and bash are steps of their session" do
    defp with_id(effect, id), do: %{effect | id: id}

    test "each change is a step, labelled by what ran; reads and runs that change nothing are not", %{ws: ws} do
      Local.run(with_id(Effect.write("a.txt", "one\n", cwd: ws), "ses-l/t1/e1"), [])
      Local.run(with_id(Effect.edit("a.txt", "one", "two", cwd: ws), "ses-l/t1/e2"), [])
      Local.run(with_id(Effect.bash("touch b.txt && echo made", cwd: ws), "ses-l/t1/e3"), [])
      Local.run(with_id(Effect.read("a.txt", cwd: ws), "ses-l/t1/e4"), [])
      Local.run(with_id(Effect.bash("ls", cwd: ws), "ses-l/t1/e5"), [])

      assert [
               %{id: "ses-l/t1/e3", label: "bash touch b.txt && echo made"},
               %{id: "ses-l/t1/e2", label: "edit a.txt"},
               %{id: "ses-l/t1/e1", label: "write a.txt"}
             ] = Xeito.Undo.steps(ws, "ses-l")

      assert {:ok, _} = Xeito.Undo.undo(ws, "ses-l", 2)
      assert File.read!(Path.join(ws, "a.txt")) == "one\n"
      refute File.exists?(Path.join(ws, "b.txt"))
    end

    test "a file outside the workspace that a command names is backed up with the step", %{ws: ws} do
      outside = ws <> "-out"
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      notes = Path.join(outside, "notes.txt")
      File.write!(notes, "old\n")

      Local.run(with_id(Effect.bash("echo new > #{notes} && echo x > in.txt", cwd: ws), "ses-l/t1/e1"), [])
      assert [%{outside: [^notes]}] = Xeito.Undo.steps(ws, "ses-l")
      assert {:ok, _} = Xeito.Undo.undo(ws, "ses-l", 1)
      assert File.read!(notes) == "old\n"
      refute File.exists?(Path.join(ws, "in.txt"))
    end

    test "a long or multi-line command is labelled by its start", %{ws: ws} do
      command = "touch c.txt\n" <> String.duplicate("# filler ", 20)
      Local.run(with_id(Effect.bash(command, cwd: ws), "ses-l/t1/e1"), [])
      assert [%{label: label}] = Xeito.Undo.steps(ws, "ses-l")
      assert label == "bash " <> String.slice("touch c.txt " <> String.duplicate("# filler ", 20), 0, 60) <> "…"
    end

    test "without an effect id, or with undo off, nothing is recorded", %{ws: ws} do
      Local.run(Effect.write("a.txt", "x", cwd: ws), [])
      Local.run(with_id(Effect.write("b.txt", "x", cwd: ws), "ses-l/t1/e1"), undo: false)
      assert Xeito.Undo.steps(ws, "ses-l") == []
      assert File.exists?(Path.join(ws, "b.txt"))
    end
  end

  test "decide runs the decider, or an override" do
    effect =
      Effect.decide(Xeito.Decisions.Triage, %{test: "t", output: "sh: esbuild: command not found"})

    assert %{value: :env_problem, decision: %{actor: :rule}} =
             Local.run(effect, decider: [deciders: []])

    assert %{value: :code_bug} = Local.run(effect, decide: fn _ -> :code_bug end)
  end

  describe "chat" do
    test "a request the machine could not fit is answered with its reason, without a model" do
      effect = Effect.chat([%{role: "system", content: "s"}], error: {:over_budget, 9, 5})
      assert %{error: {:context_window, {:over_budget, 9, 5}}} = Local.run(effect, [])
    end

    test "an ordinary request carries no error" do
      refute Map.has_key?(Effect.chat([%{role: "user", content: "hi"}]).args, :error)
    end
  end

  describe "model tiers" do
    # Ollama: loading a model (/api/generate) and a structured decision (/api/chat).
    defp ollama(conn) do
      case conn.request_path do
        "/api/generate" ->
          Req.Test.json(conn, %{"done" => true})

        "/api/chat" ->
          tokens = [~s({"), "value", ~s(":), ~s( "), "edit", ~s("})]

          logprobs =
            for t <- tokens,
                do: %{
                  "token" => t,
                  "logprob" => -0.01,
                  "top_logprobs" => if(t == "edit", do: [%{"token" => "edit", "logprob" => -0.01}], else: [])
                }

          Req.Test.json(conn, %{
            "message" => %{"content" => ~s({"value": "edit"})},
            "prompt_eval_count" => 9,
            "eval_count" => 2,
            "logprobs" => logprobs
          })
      end
    end

    defp local_tier(stub) do
      Req.Test.stub(stub, &ollama/1)
      [tiers: [local: [url: "http://large.test", plug: {Req.Test, stub}, model: "big"]]]
    end

    test "swap loads the local model and counts the swap against the run that asked" do
      run = "local-swap-#{System.unique_integer([:positive])}"
      effect = %Effect{kind: :swap, args: %{tier: :local, parent: run}, reply: :swapped}
      assert %{ok: true, ms: ms} = Local.run(effect, local_tier(:local_swap))
      assert is_integer(ms)
      assert Xeito.Budget.get(run, :swaps) == 1

      assert %{ok: true} = Local.run(%{effect | args: %{tier: :local, parent: nil}}, local_tier(:local_swap2))
    end

    test "swap reports a tier that is not configured, or that fails" do
      effect = %Effect{kind: :swap, args: %{tier: :local, parent: nil}, reply: :swapped}
      assert Local.run(effect, []) == %{ok: false, error: :tier_unavailable}

      Req.Test.stub(:local_down, &Plug.Conn.send_resp(&1, 500, "down"))
      down = [tiers: [local: [url: "http://down.test", plug: {Req.Test, :local_down}, model: "big", retry: false]]]
      assert %{ok: false, error: _} = Local.run(effect, down)
    end

    test "a tier decides, whichever run it decides for" do
      effect = %Effect{
        kind: :tier,
        args: %{tier: :local, decision: Xeito.Decisions.Intent, input: %{message: "fix it"}},
        reply: :tier_done
      }

      for run_id <- [nil, "ses-x/t1", "ses-x/t1/e2/esc"] do
        assert %{value: :edit, tier: :local} =
                 Local.run(effect, [run_id: run_id] ++ local_tier(:"local_tier_#{System.unique_integer([:positive])}"))
      end
    end
  end

  test "an effect that raised gets a result of its kind's shape, reporting the error" do
    assert Xeito.Effects.error_result(Effect.bash("x"), "boom") == %{exit_status: -1, output: "boom"}

    assert Xeito.Effects.error_result(%Effect{kind: :decide, args: %{}, reply: nil}, "boom") == %{
             value: :abstain,
             error: "boom"
           }

    assert Xeito.Effects.error_result(Effect.read("a"), "boom") == %{ok: false, error: "boom"}
  end
end
