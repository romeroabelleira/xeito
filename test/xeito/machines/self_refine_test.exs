defmodule Xeito.Machines.SelfRefineTest do
  use Xeito.Case, async: true

  alias Xeito.Effect
  alias Xeito.Machine
  alias Xeito.Machine.Engine
  alias Xeito.Machines.SelfRefine

  @ctx %{cwd: "/tmp/ws", system: "sys", request: "Condense this.", max_rounds: 2}

  defp machine, do: Machine.fetch!(SelfRefine)

  test "every step is one quiet chat call without tools, under the session's system prompt" do
    assert [
             %Effect{
               kind: :chat,
               args: %{messages: [%{role: "system", content: "sys"}, %{role: "user", content: "Condense this."}]} = args
             }
           ] =
             SelfRefine.draft(@ctx)

    assert args.tools == false
    assert args.quiet == true

    ctx = Map.merge(@ctx, %{draft: "A draft.", critique: "Too long."})
    assert [%Effect{kind: :chat, args: %{messages: [_, %{content: critique}]}}] = SelfRefine.critique(ctx)
    assert critique =~ "Draft answer:\nA draft." and critique =~ "No changes needed"

    assert [%Effect{kind: :chat, args: %{messages: [_, %{content: revise}]}}] = SelfRefine.revise(ctx)
    assert revise =~ "Critique:\nToo long." and revise =~ "Output only"
  end

  test "the draft is the answer until a revision replaces it; the Refine decision reads request, draft and critique" do
    ctx = SelfRefine.record_draft(@ctx, %{content: "First."})
    assert %{draft: "First.", answer: "First.", round: 0} = ctx

    ctx = SelfRefine.record_critique(ctx, %{content: "Missing the date."})
    assert SelfRefine.refine_input(ctx) == %{request: "Condense this.", draft: "First.", critique: "Missing the date."}

    assert %{draft: "Second.", answer: "Second.", round: 1} = SelfRefine.record_revision(ctx, %{content: "Second."})
  end

  test "steps: draft, critique, judge; done stands, revise revises while rounds are left, a model error fails" do
    m = machine()
    reply = %{content: "text", model: "m", tool_calls: [], tokens_in: 1, tokens_out: 1}

    assert {:ok, %{to: :critiquing, ctx: %{draft: "text"}}} = Engine.handle(m, :drafting, @ctx, :chatted, reply)
    assert {:ok, %{to: :failed, ctx: %{error: :boom}}} = Engine.handle(m, :drafting, @ctx, :chatted, %{error: :boom})

    ctx = SelfRefine.record_draft(@ctx, reply)
    assert {:ok, %{to: :judging, ctx: %{critique: "text"}}} = Engine.handle(m, :critiquing, ctx, :chatted, reply)

    ctx = SelfRefine.record_critique(ctx, reply)
    assert {:ok, %{to: :done}} = Engine.handle(m, :judging, ctx, {:decided, :done}, %{value: :done})
    assert {:ok, %{to: :done}} = Engine.handle(m, :judging, ctx, {:decided, :abstain}, %{value: :abstain})
    assert {:ok, %{to: :revising}} = Engine.handle(m, :judging, ctx, {:decided, :revise}, %{value: :revise})

    # The first revision is critiqued again; the second, the last of two rounds, is final.
    assert {:ok, %{to: :critiquing, ctx: %{round: 1}}} = Engine.handle(m, :revising, ctx, :chatted, reply)

    assert {:ok, %{to: :done, ctx: %{round: 2, answer: "text"}}} =
             Engine.handle(m, :revising, %{ctx | round: 1}, :chatted, reply)

    assert {:ok, %{to: :done}} = Engine.handle(m, :revising, Map.put(ctx, :max_rounds, 1), :chatted, reply)
  end
end
