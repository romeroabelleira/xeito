defmodule Xeito.Client.RenderTest do
  use ExUnit.Case, async: true

  alias Xeito.Client.Render

  defp line(type, attrs, run \\ "ses-1/t1"), do: Render.line(%{"event" => type, "run" => run, "attrs" => attrs})

  defp requested(kind, args), do: line("effect_requested", %{"kind" => kind, "args" => args})
  defp completed(kind, result), do: line("effect_completed", %{"kind" => kind, "result" => result})

  describe "runs" do
    test "escalation and intent runs are folded into their decision" do
      assert line("state_entered", %{"state" => "classify"}, "ses-1/t1/esc") == ""
      assert line("state_entered", %{"state" => "classify"}, "ses-1/t1/intent") == ""
    end

    test "delegated runs are indented one level per delegation; an event without a run is not" do
      assert line("state_entered", %{"state" => "fix"}, "ses-1/t1/e2/run") == "  · fix\n"

      assert line("state_entered", %{"state" => "summarising"}) ==
               "· summarising the earliest turns, which no longer fit the context window\n"

      assert line("state_entered", %{"state" => "fix"}, "ses-1/t1/e2/run/e1/run") == "    · fix\n"
      assert Render.line(%{"event" => "notice", "attrs" => %{"text" => "hi"}}) == "hi\n"
    end
  end

  describe "decisions" do
    test "intent and decisions show value, actor and confidence" do
      assert line("intent", %{"value" => "edit", "actor" => "local", "confidence" => 0.9}) ==
               "◆ intent: edit (local 0.90)\n"

      assert line("decision_made", %{
               "decision_type" => "Elixir.Xeito.Decisions.NextStep",
               "value" => "verify",
               "actor" => "rule",
               "confidence" => 1
             }) == "◆ next_step: verify (rule 1.00)\n"

      assert line("intent", %{"value" => "run", "actor" => "rule"}) =~ "(rule -)"
      assert line("intent", %{"value" => "run", "actor" => "rule", "confidence" => "high"}) =~ "(rule high)"
    end

    test "a selected run names its machine and why" do
      assert line("run_selected", %{"machine" => "Elixir.Xeito.Machines.Chat", "reason" => "intent"}) ==
               "  → Chat · intent\n"
    end
  end

  describe "requested effects" do
    test "bash, write, delegation, and a chat call that only indents its streamed text" do
      assert requested("bash", %{"cmd" => "mix test"}) == "  $ mix test\n"
      assert requested("write", %{"path" => "a.ex", "content" => "x\ny"}) == "  write a.ex (2 lines)\n"
      assert requested("write", %{"path" => "a.ex"}) == "  write a.ex (0 lines)\n"
      assert requested("machine", %{"machine" => "Elixir.Xeito.Machines.Fix"}) == "  ↳ delegating to Fix\n"
      assert line("effect_requested", %{"kind" => "chat", "args" => %{}}, "ses-1/t1/e1/run") == "  "
      assert requested("bash", %{"nope" => 1}) == ""
    end

    test "reads say what they read" do
      assert requested("read", %{"path" => "a.ex"}) == "  read a.ex\n"
      assert requested("read", %{"path" => "a.ex", "lines" => "3-9"}) == "  read a.ex · lines 3-9\n"
      assert requested("read", %{"path" => "a.ex", "symbol" => "f/1"}) == "  read a.ex · f/1\n"
      assert requested("read", %{"path" => "a.ex", "outline" => true}) == "  outline a.ex\n"
      assert requested("read", %{"path" => "", "result" => 4}) == "  read result 4\n"
    end

    test "an edit shows a compact diff, a few lines of each side" do
      assert requested("edit", %{"path" => "a.ex", "old" => "a", "new" => "b\nc"}) ==
               "  edit a.ex\n    - a\n    + b\n    + c\n"

      long = Enum.map_join(1..9, "\n", &"l#{&1}")
      diff = requested("edit", %{"path" => "a.ex", "old" => long, "new" => "x"})
      assert diff =~ "    - l6\n    - … 3 more\n    + x\n"
      refute diff =~ "l7"
      assert requested("edit", %{"path" => "a.ex"}) == "  edit a.ex\n"
    end
  end

  describe "completed effects" do
    test "bash shows its exit status and the last line of its output" do
      assert completed("bash", %{"exit_status" => 1, "output" => "a\nfailed: 2 tests\n"}) ==
               "    exit 1 · failed: 2 tests\n"

      assert completed("bash", %{"exit_status" => 0, "output" => ""}) == "    exit 0\n"
    end

    test "a model call ends its streamed text, or shows its error" do
      assert completed("chat", %{"text" => "hi"}) == "\n"
      assert completed("chat", %{"error" => :timeout}) == "\n  ✗ model error: :timeout\n"
    end

    test "failed file tools show the error; an edit that broke the syntax warns" do
      assert completed("read", %{"ok" => false, "error" => "enoent"}) == "    ✗ enoent\n"
      assert completed("edit", %{"ok" => true, "syntax_error" => "line 3"}) == "    ⚠ no longer parses: line 3\n"
      assert completed("read", %{"ok" => true, "syntax_error" => "x"}) == ""
      assert completed("write", %{"ok" => true}) == ""
    end
  end

  describe "states, reviews, pauses and the end of a turn" do
    test "the chat loop's own states are hidden, others shown" do
      for s <- ~w(risk_check thinking executing answered), do: assert(line("state_entered", %{"state" => s}) == "")
      assert line("state_entered", %{"state" => "ask_human"}) == "· ask_human\n"
    end

    test "a review says what it is about" do
      review = &line("human_needed", %{"call" => &1})

      assert review.(%{"tool" => "bash", "arguments" => %{"command" => "rm x"}}) ==
               "? review: run `rm x` — y approves, n denies, or say what to do instead\n"

      assert review.(%{"summary" => "write a.ex"}) =~ "review: write a.ex —"
      assert review.(%{"tool" => "edit"}) =~ "review: edit —"
      assert review.(%{}) =~ "review: continue —"
    end

    test "a pause names the decision or effect it stopped before" do
      decision = %{
        "decision" => "Elixir.Xeito.Decisions.Risk",
        "value" => "safe",
        "actor" => "local_decision",
        "confidence" => 0.5
      }

      assert line("paused", %{"state" => "risk_check", "summary" => decision}) ==
               "‖ paused in risk_check before Risk: safe (local_decision 0.50) — /next · /decide <value> · /continue\n"

      assert line("paused", %{"state" => "verifying", "kind" => "bash", "summary" => %{"exit_status" => 0}}) =~
               "before bash exit 0 —"

      assert line("paused", %{"state" => "executing", "kind" => "read"}) =~ "before read result —"
    end

    test "the end of a turn: a mark, the final state, and the first line of an answer not streamed" do
      assert line("turn_finished", %{"status" => "done", "final_state" => "answered", "answer" => "hi"}) == "✓ answered\n"

      assert line("turn_finished", %{"status" => "done", "final_state" => "fixed", "answer" => "  All green.\nMore."}) ==
               "✓ fixed · All green.\n"

      assert line("turn_finished", %{"status" => "failed", "final_state" => "failed", "answer" => nil}) == "✗ failed\n"
      assert line("turn_finished", %{"status" => "done", "final_state" => "fixed", "answer" => ""}) == "✓ fixed\n"

      assert line("turn_finished", %{"status" => :halted, "final_state" => :executing, "answer" => "Halted by the user."}) ==
               "■ executing · Halted by the user.\n"
    end

    test "streamed text, notices, errors and a closed session; unknown events show nothing" do
      assert line("delta", %{"text" => "par"}, "ses-1/t1/e1/run") == "par"
      assert line("error", %{"text" => "boom"}) == "✗ boom\n"
      assert Render.line(%{"event" => "closed"}) =~ "session closed while idle"
      assert line("tick", %{}) == ""
    end
  end
end
