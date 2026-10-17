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
    failure the model sees the output and may fix it (`Chat.Limits`: `@max_fixes` times, within
    `@fix_budget` model turns past `max_steps`). A turn that still fails says so in the answer.
  - `skills: [skill]`: adds the `skill` tool.
  - `skill_candidates: [%{name, description}]`: `Xeito.Decisions.Skill` picks one (or none) in
    `choosing_skill`; it is suggested in the turn's user message, never in the system prompt.
  - `tools: false`: a plain answer with no tools; `tools: [name]`: only those tools.
  - `context`: the context window in tokens (default `Chat.Request`'s `@default_context`).
  - `format`: a JSON Schema the answers (`thinking`, `wrapping_up`) must match.

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

  The work behind the guards and actions is in `Chat.Request` (the model requests),
  `Chat.Elision`, `Chat.Transcript` (the messages a step adds to the turn), `Chat.Calls` (which
  calls run, repeats), `Chat.Limits` (steps, fixes, stopping), `Chat.Checks` and `Chat.Steering`.
  """

  use Xeito.Machine, version: "0.13.0"

  alias Xeito.Chat.Window
  alias Xeito.Effect
  alias Xeito.Machines.Chat.Calls
  alias Xeito.Machines.Chat.Checks
  alias Xeito.Machines.Chat.Limits
  alias Xeito.Machines.Chat.Request
  alias Xeito.Machines.Chat.Steering
  alias Xeito.Machines.Chat.Transcript
  alias Xeito.Tools

  @human_timeout 86_400_000
  @verify_timeout 900_000

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
    # The model's window is smaller than the context said: a smaller window, a summary if one is
    # due before the turn starts, and one more try.
    on :chatted, to: :summarising, guard: :overflow_summary?, action: :shrink_window
    on :chatted, to: :thinking, guard: :overflow?, action: :shrink_window
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

  final :answered
  final :failed

  # --- entry functions ---------------------------------------------------------------------

  @doc "The default system prompt; the session adds project context."
  @spec default_system() :: String.t()
  defdelegate default_system, to: Request

  @doc false
  def ask_model(ctx), do: [Request.chat(ctx, Request.outgoing(ctx), [tools: Tools.names_for(ctx)] ++ format(ctx))]

  @doc false
  def ask_wrap_up(ctx),
    do: [Request.chat(ctx, Request.outgoing(ctx) ++ [Request.wrap_up(ctx)], [tools: false] ++ format(ctx))]

  defp format(%{format: schema}), do: [format: schema]
  defp format(_ctx), do: []

  @doc false
  def ask_summary(ctx) do
    {span, _kept} = Window.summary_split(Map.get(ctx, :messages, []), Request.window(ctx))
    [Effect.chat(Window.summary_request(span, Request.window(ctx)), tools: false, quiet: true, reply: :summarised)]
  end

  @doc false
  def run_checks(ctx), do: [Effect.bash(ctx.verify, cwd: ctx.cwd, timeout: @verify_timeout, reply: :verified)]

  @doc false
  def run_tool(%{current: call} = ctx) do
    {:ok, effect} = Tools.to_effect(call, ctx)
    [effect]
  end

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
  def risk_input(%{current: %{arguments: %{"command" => command}}} = ctx), do: %{command: command, cwd: ctx[:cwd]}

  # --- guards ------------------------------------------------------------------------------

  @doc false
  def chat_error?(_ctx, message), do: Map.has_key?(message, :error)

  @doc false
  def overflow?(ctx, message), do: match?({:context_overflow, _}, message[:error]) and not Map.get(ctx, :shrunk, false)

  @doc false
  def overflow_summary?(ctx, message),
    do: overflow?(ctx, message) and not match?([_ | _], ctx[:turn]) and summary_due?(Request.shrink(ctx), nil)

  @doc false
  def summary_due?(ctx, _decision), do: Window.summary_split(Map.get(ctx, :messages, []), Request.window(ctx)) != :keep

  @doc false
  def summary_failed?(ctx, message), do: chat_error?(ctx, message) or String.trim(Map.get(message, :content) || "") == ""

  @doc false
  def calls_next_risky?(ctx, message), do: Calls.next_is?(Calls.valid(message, ctx), true)

  @doc false
  def calls_next_safe?(ctx, message), do: Calls.next_is?(Calls.valid(message, ctx), false)

  @doc false
  def only_invalid_calls?(ctx, message), do: Map.get(message, :tool_calls, []) != [] and Calls.valid(message, ctx) == []

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
  def calls_at_limit?(ctx, message), do: Map.get(message, :tool_calls, []) != [] and Limits.last_step?(ctx)

  @doc false
  def next_risky?(ctx, _result), do: Calls.next_is?(ctx.pending, true)

  @doc false
  def next_safe?(ctx, _result), do: Calls.next_is?(ctx.pending, false)

  @doc false
  def step_limit?(ctx, _data), do: Limits.at_limit?(ctx)

  @doc false
  def edited?(ctx, _data), do: Checks.verify?(ctx) and Map.get(ctx, :edited, false)

  @doc false
  def calls_at_limit_edited?(ctx, message), do: calls_at_limit?(ctx, message) and edited?(ctx, message)

  @doc false
  def step_limit_edited?(ctx, result),
    do: step_limit?(ctx, result) and Checks.verify?(ctx) and (ctx[:edited] || Calls.edit_done?(ctx, result))

  @doc false
  def checks_passed?(_ctx, result), do: result.exit_status == 0

  @doc false
  def can_fix?(ctx, _result), do: Limits.can_fix?(ctx)

  # --- actions -----------------------------------------------------------------------------

  @doc false
  def suggest_first(ctx, _decision), do: suggest(ctx, 0)
  @doc false
  def suggest_second(ctx, _decision), do: suggest(ctx, 1)
  @doc false
  def suggest_third(ctx, _decision), do: suggest(ctx, 2)

  defp suggest(ctx, n), do: Map.put(ctx, :suggested_skill, Enum.at(Map.get(ctx, :skill_candidates, []), n))

  @doc "Replaces the summarised turns of `ctx.messages` with the summary."
  def record_summary(ctx, message) do
    {span, kept} = Window.summary_split(ctx.messages, Request.window(ctx))
    Map.put(ctx, :messages, [Window.summary_message(message.content, span) | kept])
  end

  @doc false
  def queue_calls(ctx, message) do
    {valid, rejected} = Calls.sort(message, ctx)
    errors = for {call, reason} <- rejected, do: Transcript.tool(call, reason)

    ctx
    |> Transcript.add_tokens(message)
    |> Transcript.put_reply([Transcript.assistant(message) | errors] ++ Calls.stuck_note(ctx, message))
    |> Calls.remember(message, valid)
    |> Map.update(:steps, 1, &(&1 + 1))
    |> advance(valid)
  end

  @doc false
  def queue_calls_and_stop(ctx, message), do: ctx |> queue_calls(message) |> Limits.stop(:invalid)

  @doc false
  def queue_calls_and_nudge(ctx, message) do
    ctx
    |> queue_calls(message)
    |> Transcript.put_turn([Calls.nudge()])
    |> Map.put(:nudged, true)
  end

  @doc false
  def record_answer(ctx, message) do
    ctx
    |> Transcript.add_tokens(message)
    |> Transcript.put_reply([Transcript.assistant(message)])
    |> Map.update(:steps, 1, &(&1 + 1))
    |> Map.put(:answer, Transcript.answer(message))
  end

  @doc false
  def record_wrap_up(ctx, %{error: _}), do: ctx

  def record_wrap_up(ctx, message) do
    ctx =
      ctx
      |> Transcript.add_tokens(message)
      |> Transcript.put_reply([Request.wrap_up(ctx), Transcript.assistant(message)])

    case message |> Map.get(:content, "") |> to_string() |> String.trim() do
      "" -> ctx
      text -> Map.update(ctx, :answer, text, &(&1 <> "\n\n" <> text))
    end
  end

  @doc false
  def record_calls_and_stop(ctx, message) do
    ctx
    |> Transcript.add_tokens(message)
    |> Transcript.put_reply([Transcript.assistant(message)])
    |> Map.update(:steps, 1, &(&1 + 1))
    |> advance([])
    |> Limits.stop()
  end

  @doc false
  def shrink_window(ctx, _message), do: Request.shrink(ctx)

  @doc false
  def record_error(ctx, message), do: Map.put(ctx, :error, message.error)

  @doc false
  def record_result(ctx, result) do
    edit_done? = Calls.edit_done?(ctx, result)

    ctx
    |> Map.update(:edited, edit_done?, &(&1 or edit_done?))
    # An edit may change what a repeat would see: repeats are allowed again.
    |> then(&if(edit_done?, do: Calls.forget(&1), else: Calls.remember_result(&1, result)))
    |> Transcript.put_turn([Transcript.tool(ctx.current, Tools.result_text(result), result)])
    |> advance(ctx.pending)
  end

  @doc false
  def record_result_and_stop(ctx, result), do: ctx |> record_result(result) |> Limits.stop()

  @doc false
  def record_checks(ctx, result), do: Checks.record(ctx, result)

  @doc false
  def report_failure(ctx, result) do
    ctx
    |> Transcript.put_turn([Checks.fix_prompt(ctx, result)])
    |> Map.update(:fixes, 1, &(&1 + 1))
    |> Map.put(:fixing, true)
    |> Map.drop([:answer, :stopped])
  end

  @doc false
  def forbid(ctx, _result), do: refuse(ctx, "blocked: the Risk decision classified this command as forbidden")

  @doc false
  def forbid_and_stop(ctx, result), do: ctx |> forbid(result) |> Limits.stop()

  @doc false
  def deny(ctx, _data), do: refuse(ctx, "denied: the user did not approve this command")

  @doc false
  def deny_and_stop(ctx, data), do: ctx |> deny(data) |> Limits.stop()

  @doc false
  def instruct(ctx, %{text: text}), do: refuse(ctx, "not run: instead of approving, the user said: " <> text)

  @doc false
  def instruct_and_stop(ctx, data), do: ctx |> instruct(data) |> Limits.stop()

  defp refuse(ctx, reason) do
    skipped = for call <- ctx.pending, do: Transcript.tool(call, "skipped: an earlier call was refused")

    ctx
    |> Transcript.put_turn([Transcript.tool(ctx.current, reason) | skipped])
    |> advance([])
  end

  defp advance(ctx, [next | rest]), do: Map.merge(ctx, %{current: next, pending: rest})
  defp advance(ctx, []), do: Map.merge(ctx, %{current: nil, pending: []})

  # --- steering ----------------------------------------------------------------------------

  @doc "A line from the user while the turn works, for the next model request."
  @spec steer(map(), %{text: String.t()}) :: map()
  defdelegate steer(ctx, data), to: Steering

  @doc "A line from the user during a model call, held until the reply arrives."
  @spec steer_late(map(), %{text: String.t()}) :: map()
  defdelegate steer_late(ctx, data), to: Steering

  @doc "The steers not yet given to the model, oldest first."
  @spec undelivered(map()) :: [String.t()]
  defdelegate undelivered(ctx), to: Steering
end
