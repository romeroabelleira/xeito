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
    assert String.trim(output) == Path.expand(ws)
    assert %{exit_status: 3} = Local.run(Effect.bash("exit 3", cwd: ws), [])
  end

  test "bash times out", %{ws: ws} do
    assert %{exit_status: 124} = Local.run(Effect.bash("sleep 5", cwd: ws, timeout: 50), [])
  end

  test "write and read stay inside the workspace", %{ws: ws} do
    assert %{ok: true} = Local.run(Effect.write("sub/a.txt", "hello", cwd: ws), [])
    assert %{ok: true, content: "hello"} = Local.run(Effect.read("sub/a.txt", cwd: ws), [])

    assert %{ok: false, error: :outside_workspace} =
             Local.run(Effect.read("../../etc/passwd", cwd: ws), [])

    assert %{ok: false, error: :outside_workspace} =
             Local.run(Effect.write("/tmp/x", "no", cwd: ws), [])
  end

  test "decide runs the decider, or an override" do
    effect =
      Effect.decide(Xeito.Decisions.Triage, %{test: "t", output: "sh: esbuild: command not found"})

    assert %{value: :env_problem, decision: %{actor: :rule}} =
             Local.run(effect, decider: [deciders: []])

    assert %{value: :code_bug} = Local.run(effect, decide: fn _ -> :code_bug end)
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

    defp large(stub) do
      Req.Test.stub(stub, &ollama/1)
      [tiers: [large: [url: "http://large.test", plug: {Req.Test, stub}, model: "big"]]]
    end

    test "swap loads the large model and counts the swap against the run that asked" do
      run = "local-swap-#{System.unique_integer([:positive])}"
      effect = %Effect{kind: :swap, args: %{tier: :large, parent: run}, reply: :swapped}
      assert %{ok: true, ms: ms} = Local.run(effect, large(:local_swap))
      assert is_integer(ms)
      assert Xeito.Budget.get(run, :swaps) == 1

      assert %{ok: true} = Local.run(%{effect | args: %{tier: :large, parent: nil}}, large(:local_swap2))
    end

    test "swap reports a tier that is not configured, or that fails" do
      effect = %Effect{kind: :swap, args: %{tier: :large, parent: nil}, reply: :swapped}
      assert Local.run(effect, []) == %{ok: false, error: :tier_unavailable}

      Req.Test.stub(:local_down, &Plug.Conn.send_resp(&1, 500, "down"))
      down = [tiers: [large: [url: "http://down.test", plug: {Req.Test, :local_down}, model: "big", retry: false]]]
      assert %{ok: false, error: _} = Local.run(effect, down)
    end

    test "a tier decides, whichever run it decides for" do
      effect = %Effect{
        kind: :tier,
        args: %{tier: :large, decision: Xeito.Decisions.Intent, input: %{message: "fix it"}},
        reply: :tier_done
      }

      for run_id <- [nil, "ses-x/t1", "ses-x/t1/e2/esc"] do
        assert %{value: :edit, tier: :large} =
                 Local.run(effect, [run_id: run_id] ++ large(:"local_tier_#{System.unique_integer([:positive])}"))
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
