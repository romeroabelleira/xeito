defmodule Xeito.Machines.SelfRefine do
  @moduledoc """
  Draft, critique, revise: a strategy for a one-shot prose answer, as a machine (P4g step 6).

  An experiment, not a default: measured against one chat call on the local model on 2026-10-31
  (`bench/scripts/p4g_strategies.exs`), it won 2 of 12 prose tasks, lost 2 and tied 8, at twice the
  wall time, so no `--strategy` flag ships; `mix xeito.run --machine self_refine` runs it, and the
  benchmark can be repeated with another model.

      drafting ──chatted──→ critiquing ──chatted──→ judging ─┬─ done ─────────→ done
                                                            └─ revise ───────→ revising ──chatted──→ critiquing
                                                                                                 └─ (last round) → done

  * Each step is one `chat` effect without tools and not streamed: the system prompt and the
    request are what a plain chat turn would send. The critique and every revision are logged, so
    the benchmark can say whether a round improved the answer.
  * `Xeito.Decisions.Refine` decides, on the critique, whether the draft stands or a revision is
    due; `max_rounds` (default 2) caps the revisions, and the last one is not critiqued again.
  * The answer is the latest draft (`ctx.answer`); a model error ends the run in `failed`.

  Input: `%{request: text, system: prompt, cwd: path}`, optionally `max_rounds`.
  """

  use Xeito.Machine, version: "0.1.0"

  alias Xeito.Effect

  @default_rounds 2

  initial :drafting

  state :drafting, entry: :draft, timeout: 900_000 do
    on :chatted, to: :failed, guard: :chat_error?, action: :record_error
    on :chatted, to: :critiquing, action: :record_draft
  end

  state :critiquing, entry: :critique, timeout: 900_000 do
    on :chatted, to: :failed, guard: :chat_error?, action: :record_error
    on :chatted, to: :judging, action: :record_critique
  end

  state :judging, timeout: 600_000 do
    decide(Xeito.Decisions.Refine, input: :refine_input)
    on {:decided, :done}, to: :done
    on {:decided, :revise}, to: :revising
    on {:decided, :abstain}, to: :done
  end

  state :revising, entry: :revise, timeout: 900_000 do
    on :chatted, to: :failed, guard: :chat_error?, action: :record_error
    on :chatted, to: :done, guard: :last_round?, action: :record_revision
    on :chatted, to: :critiquing, action: :record_revision
  end

  final :done
  final :failed

  # --- entry functions ---------------------------------------------------------------------

  @doc false
  def draft(ctx), do: [chat(ctx, ctx.request)]

  @doc false
  def critique(ctx) do
    [
      chat(ctx, """
      Request:
      #{ctx.request}

      Draft answer:
      #{ctx.draft}

      Critique the draft against the request: what is wrong, missing, unclear, or longer than it \
      needs to be. Be specific and brief. If the draft fully answers the request and needs no \
      change, answer exactly: No changes needed.
      """)
    ]
  end

  @doc false
  def revise(ctx) do
    [
      chat(ctx, """
      Request:
      #{ctx.request}

      Draft answer:
      #{ctx.draft}

      Critique:
      #{ctx.critique}

      Rewrite the draft so that it addresses the critique and answers the request. Output only \
      the revised answer.
      """)
    ]
  end

  defp chat(ctx, user) do
    Effect.chat([%{role: "system", content: ctx.system}, %{role: "user", content: user}], tools: false, quiet: true)
  end

  @doc "The Refine decision's input: the request, the draft and its critique."
  @spec refine_input(map()) :: %{request: String.t(), draft: String.t(), critique: String.t()}
  def refine_input(ctx), do: %{request: ctx.request, draft: ctx.draft, critique: ctx.critique}

  # --- guards ------------------------------------------------------------------------------

  @doc false
  def chat_error?(_ctx, message), do: Map.has_key?(message, :error)

  @doc false
  def last_round?(ctx, _message), do: Map.get(ctx, :round, 0) + 1 >= Map.get(ctx, :max_rounds, @default_rounds)

  # --- actions -----------------------------------------------------------------------------

  @doc false
  def record_draft(ctx, message), do: Map.merge(ctx, %{draft: message.content, answer: message.content, round: 0})

  @doc false
  def record_critique(ctx, message), do: Map.put(ctx, :critique, message.content)

  @doc false
  def record_revision(ctx, message),
    do: Map.merge(ctx, %{draft: message.content, answer: message.content, round: Map.get(ctx, :round, 0) + 1})

  @doc false
  def record_error(ctx, message), do: Map.put(ctx, :error, message.error)
end
