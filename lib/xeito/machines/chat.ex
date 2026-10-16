defmodule Xeito.Machines.Chat do
  @moduledoc """
  The free chat machine: one user turn of the agent loop (model calls, tool calls, checks) as a statechart.

      choosing_skill ──decided──┬─ earlier turns too long → summarising ──summarised──→ thinking
                                └─ otherwise ───────────────────────────────────────→ thinking
      thinking ──chatted──┬─ tool calls, next is bash ─→ risk_check ─┬─ safe ──────→ executing
                          ├─ tool calls, other ───────→ executing   ├─ review/abstain → ask_human
                          ├─ no tool calls, edited ───→ verifying   └─ forbidden ─→ thinking (told)
                          └─ no tool calls ───────────→ answered
      executing ──tool_done──→ next call (risk_check | executing) | thinking
                               | verifying or answered (step limit)
      verifying ──verified──┬─ passed ─────────────────────→ answered
                            ├─ failed, fixes left ─────────→ thinking (told the output)
                            └─ failed, no fixes left → answered (with the failure noted)
      ask_human ──approved──→ executing · ──denied──→ thinking (told)
                · ──instructed (a text answer)──→ thinking (told what to do instead)
      any working state ──steered──→ itself (internal: the line waits for the next model call)

  Input: `%{cwd: path, prompt: text, messages: [earlier messages], system: text, max_steps: n}`, and optionally:

  - `verify: command`: a turn that edited files (`write`/`edit`) runs it before answering; on
    failure the model sees the output and may fix it (`@max_fixes` times, within `@fix_budget`
    model turns past `max_steps`). A turn that still fails says so in the answer.
  - `skills: [skill]`: adds the `skill` tool.
  - `skill_candidates: [%{name, description}]`: `Xeito.Decisions.Skill` picks one (or none) in
    `choosing_skill`; it is suggested in the turn's user message, never in the system prompt.
  - `tools: false`: a plain answer with no tools.
  - `context`: the context window in tokens (default `@default_context`).

  Output: ends in `answered` with `ctx.answer` and `ctx.turn` (the turn's full message list,
  system prompt first), or in `failed` with `ctx.error`.

  - Tool calls are proposals: each becomes an effect (`Xeito.Tools`); `bash` passes
    `Xeito.Decisions.Risk` first; invalid calls get an error message, not a run.
  - `max_steps` (default 25) bounds model turns. A stopped turn gets one last tool-less model
    turn (`wrapping_up`) to report.
  - An exact repeat of a call made in this turn is answered with the earlier result. A second
    step in a row of only repeated or invalid calls ends the turn, except once in a turn that
    changed nothing yet: then the model is nudged and keeps its tools.
  - When the earlier conversation outgrows the request budget, `summarising` replaces its oldest
    turns with a summary in `ctx.messages` (so also in `ctx.turn`). A failed summary changes nothing.
  """

  use Xeito.Machine, version: "0.12.0"

  alias Xeito.Chat.Window
  alias Xeito.Effect
  alias Xeito.Tools
  alias Xeito.Tools.Shape

  @human_timeout 86_400_000
  @verify_timeout 900_000
  @max_fixes 2
  # Model turns past `max_steps` for fixing a failing check, shared by all fixes.
  @fix_budget 4
  @output_tail 4_000
  # Context window when the input names none, and the part kept free for the reply.
  @default_context 32_768
  @output_reserve 8_192

  initial :choosing_skill

  state :choosing_skill do
    decide(Xeito.Decisions.Skill, input: :skill_input)
    on {:decided, :first}, to: :summarising, guard: :summary_due?, action: :suggest_first
    on {:decided, :first}, to: :thinking, action: :suggest_first
    on {:decided, :second}, to: :summarising, guard: :summary_due?, action: :suggest_second
    on {:decided, :second}, to: :thinking, action: :suggest_second
    on {:decided, :third}, to: :summarising, guard: :summary_due?, action: :suggest_third
    on {:decided, :third}, to: :thinking, action: :suggest_third
    on {:decided, :none}, to: :summarising, guard: :summary_due?
    on {:decided, :none}, to: :thinking
    on {:decided, :abstain}, to: :summarising, guard: :summary_due?
    on {:decided, :abstain}, to: :thinking
    on :steered, action: :steer
  end

  state :summarising, entry: :ask_summary, timeout: 900_000 do
    on :summarised, to: :thinking, guard: :summary_failed?
    on :summarised, to: :thinking, action: :record_summary
    on :steered, action: :steer
  end

  state :thinking, entry: :ask_model, timeout: 900_000 do
    on :chatted, to: :failed, guard: :chat_error?, action: :record_error
    on :chatted, to: :verifying, guard: :calls_at_limit_edited?, action: :record_calls_and_stop
    on :chatted, to: :wrapping_up, guard: :calls_at_limit?, action: :record_calls_and_stop
    on :chatted, to: :risk_check, guard: :calls_next_risky?, action: :queue_calls
    on :chatted, to: :executing, guard: :calls_next_safe?, action: :queue_calls
    on :chatted, to: :verifying, guard: :invalid_again_edited?, action: :queue_calls_and_stop
    on :chatted, to: :thinking, guard: :invalid_again_unchanged?, action: :queue_calls_and_nudge
    on :chatted, to: :wrapping_up, guard: :invalid_again?, action: :queue_calls_and_stop
    on :chatted, to: :thinking, guard: :only_invalid_calls?, action: :queue_calls
    on :chatted, to: :verifying, guard: :edited?, action: :record_answer
    on :chatted, to: :answered, action: :record_answer
    # A steer during a model call waits for the reply and goes with the next request.
    on :steered, action: :steer_late
  end

  state :risk_check do
    decide(Xeito.Decisions.Risk, input: :risk_input)
    on {:decided, :safe}, to: :executing
    on {:decided, :review}, to: :ask_human
    on {:decided, :abstain}, to: :ask_human
    on {:decided, :forbidden}, to: :wrapping_up, guard: :step_limit?, action: :forbid_and_stop
    on {:decided, :forbidden}, to: :thinking, action: :forbid
    on :steered, action: :steer
  end

  state :executing, entry: :run_tool, timeout: 900_000 do
    on :tool_done, to: :risk_check, guard: :next_risky?, action: :record_result
    on :tool_done, to: :executing, guard: :next_safe?, action: :record_result
    on :tool_done, to: :verifying, guard: :step_limit_edited?, action: :record_result_and_stop
    on :tool_done, to: :wrapping_up, guard: :step_limit?, action: :record_result_and_stop
    on :tool_done, to: :thinking, action: :record_result
    on :steered, action: :steer
  end

  state :verifying, entry: :run_checks, timeout: @verify_timeout do
    on :verified, to: :wrapping_up, guard: :passed_but_stopped?, action: :record_checks
    on :verified, to: :answered, guard: :checks_passed?, action: :record_checks
    on :verified, to: :thinking, guard: :can_fix?, action: :report_failure
    on :verified, to: :wrapping_up, guard: :stopped?, action: :record_checks
    on :verified, to: :answered, action: :record_checks
    on :steered, action: :steer
  end

  state :wrapping_up, entry: :ask_wrap_up, timeout: 900_000 do
    on :chatted, to: :answered, action: :record_wrap_up
    on :steered, action: :steer_late
  end

  state :ask_human, timeout: {@human_timeout, :denied} do
    on :approved, to: :executing
    on :denied, to: :wrapping_up, guard: :step_limit?, action: :deny_and_stop
    on :denied, to: :thinking, action: :deny
    on :instructed, to: :wrapping_up, guard: :step_limit?, action: :instruct_and_stop
    on :instructed, to: :thinking, action: :instruct
    on :steered, action: :steer
  end

  # --- entry functions ---------------------------------------------------------------------

  final :answered
  final :failed

  # --- elision -------------------------------------------------------------------------------
  # Old tool output sent to the model is replaced by stubs in whole batches of @elide_batch, so
  # the prompt prefix (and the server's prompt cache) changes rarely. Kept whole: the last
  # @keep_whole outputs, small outputs and skill instructions, and the latest whole read of each
  # of the last @keep_reads project files. `ctx.turn` keeps everything; elision is pure so replay
  # reproduces it.

  @default_system """
  You are a coding assistant working in a software project. Use the tools to inspect and change
  the project: read, write, edit (exact replacement) and bash (runs in the project root). Keep
  answers short. When the task is done, answer without calling a tool.
  """

  @doc "The default system prompt; the session adds project context."
  @spec default_system() :: String.t()
  def default_system, do: @default_system

  @doc false
  def ask_model(ctx), do: [request(ctx, messages(ctx) ++ steer_messages(ctx), tools: Tools.names_for(ctx))]

  @doc false
  def ask_wrap_up(ctx), do: [request(ctx, messages(ctx) ++ steer_messages(ctx) ++ [wrap_up_request(ctx)], tools: false)]

  @doc false
  def ask_summary(ctx) do
    {span, _kept} = Window.summary_split(Map.get(ctx, :messages, []), window(ctx))
    [Effect.chat(Window.summary_request(span, window(ctx)), tools: false, quiet: true, reply: :summarised)]
  end

  # A request that cannot fit is not sent; the effect carries the reason and the turn fails.
  defp request(ctx, messages, opts) do
    window = Keyword.put(window(ctx), :keep_from, 1 + length(Map.get(ctx, :messages, [])))

    case messages |> elide() |> Window.fit(window) do
      {:ok, fitted, _report} -> Effect.chat(fitted, opts)
      {:error, reason} -> Effect.chat(messages, Keyword.put(opts, :error, reason))
    end
  end

  defp window(ctx),
    do: [
      budget: (ctx[:context] || @default_context) - @output_reserve,
      chars_per_token: Map.get(ctx, :chars_per_token, Window.default_chars_per_token())
    ]

  defp wrap_up_request(ctx) do
    why =
      case ctx[:stop_reason] do
        :invalid -> "Your last tool calls could not run, or repeated earlier ones."
        _ -> "You have used all #{ctx[:steps]} model turns for this request."
      end

    %{
      role: "user",
      content:
        why <>
          " Do not call tools. In a few sentences, tell the user what you found, what you" <>
          " changed (if anything), what is left, and what you would do next, so they can decide" <>
          " how to continue."
    }
  end

  @keep_whole 4
  @elide_batch 6
  @keep_reads 3

  @doc false
  @spec elide([map()]) :: [map()]
  def elide(messages) do
    kept = latest_reads(messages)

    candidates =
      for {%{role: "tool"} = m, i} <- Enum.with_index(messages),
          Window.elidable?(m) and i not in kept,
          do: i

    cut = div(max(length(candidates) - @keep_whole, 0), @elide_batch) * @elide_batch
    elided = candidates |> Enum.take(cut) |> MapSet.new()

    messages
    |> Enum.with_index()
    |> Enum.map(fn {m, i} -> if i in elided, do: Window.stub(m), else: m end)
  end

  defp latest_reads(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {%{read: path}, i}, latest -> Map.put(latest, path, i)
      _, latest -> latest
    end)
    |> Map.values()
    |> Enum.sort(:desc)
    |> Enum.take(@keep_reads)
    |> MapSet.new()
  end

  # --- guards ------------------------------------------------------------------------------

  @doc false
  def run_checks(ctx), do: [Effect.bash(ctx.verify, cwd: ctx.cwd, timeout: @verify_timeout, reply: :verified)]

  @doc false
  def run_tool(%{current: call} = ctx) do
    {:ok, effect} = Tools.to_effect(call, ctx)
    [effect]
  end

  defp messages(%{turn: [_ | _] = turn}), do: turn

  defp messages(ctx) do
    system = %{role: "system", content: Map.get(ctx, :system, @default_system)}
    [system | Map.get(ctx, :messages, [])] ++ [%{role: "user", content: ctx.prompt <> skill_hint(ctx[:suggested_skill])}]
  end

  defp skill_hint(nil), do: ""

  defp skill_hint(skill),
    do:
      "\n\n(A skill may fit this request; if it does, load it with the skill tool before you start: " <>
        "#{skill.name}: #{skill.description})"

  @doc "The Skill decision's input: the request and the shortlisted skills, `\"name: description\"`."
  @spec skill_input(map()) :: %{
          request: String.t(),
          first: String.t() | nil,
          second: String.t() | nil,
          third: String.t() | nil
        }
  def skill_input(ctx) do
    listed = for skill <- Map.get(ctx, :skill_candidates, []), do: "#{skill.name}: #{skill.description}"
    %{request: ctx.prompt, first: Enum.at(listed, 0), second: Enum.at(listed, 1), third: Enum.at(listed, 2)}
  end

  @doc false
  def suggest_first(ctx, _decision), do: suggest(ctx, 0)
  @doc false
  def suggest_second(ctx, _decision), do: suggest(ctx, 1)
  @doc false
  def suggest_third(ctx, _decision), do: suggest(ctx, 2)

  defp suggest(ctx, n), do: Map.put(ctx, :suggested_skill, Enum.at(Map.get(ctx, :skill_candidates, []), n))

  @doc false
  def chat_error?(_ctx, message), do: Map.has_key?(message, :error)

  @doc false
  def summary_due?(ctx, _decision), do: Window.summary_split(Map.get(ctx, :messages, []), window(ctx)) != :keep

  @doc false
  def summary_failed?(ctx, message), do: chat_error?(ctx, message) or String.trim(Map.get(message, :content) || "") == ""

  @doc "Replaces the summarised turns of `ctx.messages` with the summary."
  def record_summary(ctx, message) do
    {span, kept} = Window.summary_split(ctx.messages, window(ctx))
    Map.put(ctx, :messages, [Window.summary_message(message.content, span) | kept])
  end

  @doc false
  def calls_next_risky?(ctx, message), do: next_is?(valid(message, ctx), true)

  @doc false
  def calls_next_safe?(ctx, message), do: next_is?(valid(message, ctx), false)

  @doc false
  def only_invalid_calls?(ctx, message), do: Map.get(message, :tool_calls, []) != [] and valid(message, ctx) == []

  @doc false
  def invalid_again?(ctx, message), do: only_invalid_calls?(ctx, message) and Map.get(ctx, :invalid_streak, 0) >= 1

  @doc false
  def invalid_again_edited?(ctx, message), do: invalid_again?(ctx, message) and edited?(ctx, message)

  @doc false
  def invalid_again_unchanged?(ctx, message),
    do: invalid_again?(ctx, message) and not Map.get(ctx, :edited, false) and not Map.get(ctx, :nudged, false)

  @doc false
  def stopped?(ctx, _data), do: Map.get(ctx, :stopped, false)

  @doc false
  def passed_but_stopped?(ctx, result), do: checks_passed?(ctx, result) and stopped?(ctx, result)

  @doc false
  def calls_at_limit?(ctx, message),
    do: Map.get(message, :tool_calls, []) != [] and Map.get(ctx, :steps, 0) + 1 >= limit(ctx)

  @doc false
  def next_risky?(ctx, _result), do: next_is?(ctx.pending, true)

  @doc false
  def next_safe?(ctx, _result), do: next_is?(ctx.pending, false)

  @doc false
  def step_limit?(ctx, _data), do: Map.get(ctx, :steps, 0) >= limit(ctx)

  # --- actions -----------------------------------------------------------------------------
  @doc false
  def edited?(ctx, _data), do: verify?(ctx) and Map.get(ctx, :edited, false)

  @doc false
  def calls_at_limit_edited?(ctx, message), do: calls_at_limit?(ctx, message) and edited?(ctx, message)

  @doc false
  def step_limit_edited?(ctx, result),
    do: step_limit?(ctx, result) and verify?(ctx) and (ctx[:edited] || edit_done?(ctx, result))

  @doc false
  def checks_passed?(_ctx, result), do: result.exit_status == 0

  @doc false
  # Also at the step limit: fixing has its own budget past it.
  def can_fix?(ctx, _result),
    do: Map.get(ctx, :fixes, 0) < @max_fixes and Map.get(ctx, :steps, 0) < max_steps(ctx) + @fix_budget

  defp verify?(ctx), do: is_binary(ctx[:verify]) and ctx.verify != ""

  defp edit_done?(%{current: %{name: name}}, %{ok: true}) when name in ["write", "edit"], do: true
  defp edit_done?(_ctx, _result), do: false

  defp max_steps(ctx), do: Map.get(ctx, :max_steps, 25)

  defp limit(ctx), do: max_steps(ctx) + if(ctx[:fixing], do: @fix_budget, else: 0)

  defp next_is?([call | _], risky), do: Tools.risky?(call) == risky
  defp next_is?([], _risky), do: false

  defp valid(message, ctx), do: message |> sort_calls(ctx) |> elem(0)

  # Returns `{valid, [{call, reason}]}`; repeats count since the last edit.
  defp sort_calls(message, ctx) do
    {valid, rejected, _seen} =
      Enum.reduce(
        Map.get(message, :tool_calls, []),
        {[], [], Map.get(ctx, :seen, [])},
        &sort_call(&1, &2, ctx)
      )

    {Enum.reverse(valid), Enum.reverse(rejected)}
  end

  defp sort_call(call, {ok, bad, seen}, ctx) do
    key = {call.name, call.arguments}

    case {Tools.to_effect(call, ctx), key in seen} do
      {{:error, reason}, _} -> {ok, [{call, "error: " <> reason} | bad], seen}
      {{:ok, _}, true} -> {ok, [{call, repeated(Map.get(Map.get(ctx, :results, %{}), key))} | bad], seen}
      {{:ok, _}, false} -> {[call | ok], bad, [key | seen]}
    end
  end

  defp repeated(nil),
    do:
      "not run: you already made this exact call in this turn, and its result is above (if it " <>
        "was elided, read it back with result). Use that result instead of repeating the call; " <>
        "if you are stuck, say what blocks you."

  defp repeated(result),
    do:
      "not run again: you already made this exact call in this turn. Its result:\n\n" <>
        result <> "\n\nUse it instead of repeating the call."

  @doc false
  def queue_calls(ctx, message) do
    {valid, rejected} = sort_calls(message, ctx)
    errors = for {call, reason} <- rejected, do: tool_message(call, reason)

    ctx
    |> add_tokens(message)
    |> put_reply([assistant_message(message) | errors] ++ stuck_note(ctx, message))
    |> Map.update(
      :seen,
      Enum.map(valid, &{&1.name, &1.arguments}),
      &(Enum.map(valid, fn c -> {c.name, c.arguments} end) ++ &1)
    )
    |> Map.put(:invalid_streak, if(valid == [], do: Map.get(ctx, :invalid_streak, 0) + 1, else: 0))
    |> Map.update(:openings, [opening(message)], &[opening(message) | &1])
    |> Map.update(:steps, 1, &(&1 + 1))
    |> advance(valid)
  end

  @doc false
  def queue_calls_and_stop(ctx, message), do: ctx |> queue_calls(message) |> stop(:invalid)

  @doc false
  def queue_calls_and_nudge(ctx, message) do
    ctx
    |> queue_calls(message)
    |> put_turn([
      %{
        role: "user",
        content:
          "You already have the results you need, and repeating calls will end this turn. " <>
            "Act on them now: make the change you planned, give your answer, or say what blocks you."
      }
    ])
    |> Map.put(:nudged, true)
  end

  defp stuck_note(ctx, message) do
    opening = opening(message)

    if opening != "" and Enum.count(Map.get(ctx, :openings, []), &(&1 == opening)) >= 2,
      do: [
        %{
          role: "user",
          content:
            "You have started several steps with the same sentence and seem to be going in " <>
              "circles. Either make the change now, or stop and tell the user what blocks you."
        }
      ],
      else: []
  end

  defp opening(message) do
    message
    |> Map.get(:content, "")
    |> to_string()
    |> String.trim()
    |> String.split(~r/[.:!?\n]/, parts: 2)
    |> hd()
    |> String.slice(0, 80)
  end

  @doc false
  def record_answer(ctx, message) do
    ctx
    |> add_tokens(message)
    |> put_reply([assistant_message(message)])
    |> Map.update(:steps, 1, &(&1 + 1))
    |> Map.put(:answer, answer_text(message))
  end

  defp answer_text(message) do
    case message |> Map.get(:content, "") |> to_string() |> String.trim() do
      "" -> "(The model ended this turn without an answer.)"
      text -> text
    end
  end

  @doc false
  def record_wrap_up(ctx, %{error: _}), do: ctx

  def record_wrap_up(ctx, message) do
    ctx = ctx |> add_tokens(message) |> put_reply([wrap_up_request(ctx), assistant_message(message)])

    case message |> Map.get(:content, "") |> to_string() |> String.trim() do
      "" -> ctx
      text -> Map.update(ctx, :answer, text, &(&1 <> "\n\n" <> text))
    end
  end

  @doc false
  def record_calls_and_stop(ctx, message) do
    ctx
    |> add_tokens(message)
    |> put_reply([assistant_message(message)])
    |> Map.update(:steps, 1, &(&1 + 1))
    |> advance([])
    |> stop()
  end

  @doc false
  def record_error(ctx, message), do: Map.put(ctx, :error, message.error)

  @doc false
  def record_result(ctx, result) do
    ctx
    |> Map.update(:edited, edit_done?(ctx, result), &(&1 or edit_done?(ctx, result)))
    # An edit may change what a repeat would see: repeats are allowed again.
    |> then(&if(edit_done?(ctx, result), do: Map.merge(&1, %{seen: [], results: %{}}), else: remember_result(&1, result)))
    |> put_turn([tool_message(ctx.current, Tools.result_text(result), result)])
    |> advance(ctx.pending)
  end

  defp remember_result(ctx, result) do
    key = {ctx.current.name, ctx.current.arguments}
    Map.update(ctx, :results, %{key => Tools.result_text(result)}, &Map.put(&1, key, Tools.result_text(result)))
  end

  @doc false
  def record_result_and_stop(ctx, result), do: ctx |> record_result(result) |> stop()

  @doc false
  def record_checks(ctx, result) do
    passed = result.exit_status == 0

    ctx =
      Map.put(ctx, :checks, %{cmd: ctx.verify, exit_status: result.exit_status, passed: passed})

    if passed,
      do: ctx,
      else:
        Map.update(ctx, :answer, "", fn answer ->
          answer <>
            "\n\n⚠ The checks still fail after this turn's edits (`#{ctx.verify}`, exit #{result.exit_status})."
        end)
  end

  @doc false
  def report_failure(ctx, result) do
    text = """
    The project's checks (`#{ctx.verify}`) fail after your edits, exit status #{result.exit_status}.
    Fix the cause, or say why it cannot be fixed. You have #{max_steps(ctx) + @fix_budget - Map.get(ctx, :steps, 0)} more model turns for this. Output (tail):
    #{result[:shaped] || tail(result.output)}
    """

    ctx
    |> put_turn([%{role: "user", content: text}])
    |> Map.update(:fixes, 1, &(&1 + 1))
    |> Map.put(:fixing, true)
    |> Map.drop([:answer, :stopped])
  end

  defp tail(output) when byte_size(output) > @output_tail,
    do: "…" <> binary_part(output, byte_size(output) - @output_tail, @output_tail)

  defp tail(output), do: output

  @doc false
  def forbid(ctx, _result), do: refuse(ctx, "blocked: the Risk decision classified this command as forbidden")

  @doc false
  def forbid_and_stop(ctx, result), do: ctx |> forbid(result) |> stop()

  @doc false
  def deny(ctx, _data), do: refuse(ctx, "denied: the user did not approve this command")

  @doc false
  def deny_and_stop(ctx, data), do: ctx |> deny(data) |> stop()

  @doc false
  def instruct(ctx, %{text: text}), do: refuse(ctx, "not run: instead of approving, the user said: " <> text)

  @doc false
  def instruct_and_stop(ctx, data), do: ctx |> instruct(data) |> stop()

  @doc false
  def risk_input(%{current: %{arguments: %{"command" => command}}} = ctx), do: %{command: command, cwd: ctx[:cwd]}

  defp refuse(ctx, reason) do
    skipped =
      for call <- ctx.pending, do: tool_message(call, "skipped: an earlier call was refused")

    ctx
    |> put_turn([tool_message(ctx.current, reason) | skipped])
    |> advance([])
  end

  defp stop(ctx, reason \\ :limit) do
    notice =
      case reason do
        :limit -> "Stopped after #{ctx.steps} model turns (max_steps)."
        :invalid -> "Stopped: the model kept making tool calls that could not run."
      end

    Map.merge(ctx, %{answer: notice, stopped: true, stop_reason: reason})
  end

  defp advance(ctx, [next | rest]), do: Map.merge(ctx, %{current: next, pending: rest})
  defp advance(ctx, []), do: Map.merge(ctx, %{current: nil, pending: []})

  defp put_turn(ctx, new_messages) do
    Map.put(ctx, :turn, messages(ctx) ++ new_messages)
  end

  # --- steering ---

  # Steers the request carried go just before the reply; late ones go with the next request.
  defp put_reply(ctx, new_messages) do
    ctx
    |> put_turn(steer_messages(ctx) ++ new_messages)
    |> Map.put(:steers, Map.get(ctx, :late_steers, []))
    |> Map.put(:late_steers, [])
  end

  defp steer_messages(ctx),
    do:
      for(text <- Map.get(ctx, :steers, []), do: %{role: "user", content: "(The user, while you were working:) " <> text})

  @doc "A line from the user while the turn works, for the next model request."
  @spec steer(map(), %{text: String.t()}) :: map()
  def steer(ctx, %{text: text}), do: Map.update(ctx, :steers, [text], &(&1 ++ [text]))

  @doc "A line from the user during a model call, held until the reply arrives."
  @spec steer_late(map(), %{text: String.t()}) :: map()
  def steer_late(ctx, %{text: text}), do: Map.update(ctx, :late_steers, [text], &(&1 ++ [text]))

  @doc "The steers not yet given to the model, oldest first."
  @spec undelivered(map()) :: [String.t()]
  def undelivered(ctx), do: Map.get(ctx, :steers, []) ++ Map.get(ctx, :late_steers, [])

  defp add_tokens(ctx, message) do
    tokens_in = Map.get(message, :tokens_in, 0)
    tokens_out = Map.get(message, :tokens_out, 0)

    ctx
    |> Map.update(:tokens_in, tokens_in, &(&1 + tokens_in))
    |> Map.update(:tokens_out, tokens_out, &(&1 + tokens_out))
    |> measure_window(tokens_in)
  end

  # Relies on `ctx` still being as sent: the server's count calibrates the next estimate.
  defp measure_window(ctx, 0), do: ctx

  defp measure_window(ctx, tokens_in) do
    sent = (messages(ctx) ++ steer_messages(ctx)) |> elide() |> Window.characters()

    ctx
    |> Map.put(:chars_per_token, Window.calibrate(sent, tokens_in))
    |> Map.put(:context_truncated, ctx[:context_truncated] == true or Window.truncated?(tokens_in, ctx[:context]))
  end

  defp assistant_message(message) do
    calls =
      for c <- Map.get(message, :tool_calls, []),
          do: %{function: %{name: c.name, arguments: c.arguments}}

    then(
      %{role: "assistant", content: Map.get(message, :content, "")},
      &if(calls == [], do: &1, else: Map.put(&1, :tool_calls, calls))
    )
  end

  defp tool_message(call, text), do: %{role: "tool", tool_name: call.name, content: text}

  defp tool_message(call, text, %{ref: ref} = result) do
    call
    |> tool_message(text)
    |> Map.merge(%{ref: ref, about: about(call)})
    |> Map.merge(whole_read(call, result))
  end

  defp tool_message(call, text, _result), do: tool_message(call, text)

  defp whole_read(%{name: "read", arguments: %{"path" => path} = args}, %{ok: true})
       when is_binary(path) and path != "" do
    partial? = Enum.any?(~w(symbol lines outline result), &Map.has_key?(args, &1))
    if partial? or Shape.third_party?(path), do: %{}, else: %{read: path}
  end

  defp whole_read(_call, _result), do: %{}

  defp about(%{name: "bash", arguments: %{"command" => cmd}}), do: "output of `" <> clip(cmd) <> "`"
  defp about(%{name: "read", arguments: %{"path" => path} = args}) when path != "", do: "read of #{path}" <> detail(args)

  defp about(%{name: "read", arguments: %{"result" => ref}}), do: "full output of #{ref}"
  defp about(%{name: name}), do: "#{name} result"

  defp clip(cmd), do: if(String.length(cmd) > 80, do: String.slice(cmd, 0, 80) <> "…", else: cmd)

  defp detail(args) do
    case args["symbol"] || args["lines"] || (args["outline"] == true && "outline") do
      detail when detail in [nil, false] -> ""
      detail -> " (#{detail})"
    end
  end
end
