defmodule Xeito.Machines.Chat do
  @moduledoc """
  The free chat machine: pi's agent loop drawn as a statechart, and therefore logged and mined
  (`docs/architecture/07-harness-frontend.md#the-free-chat-machine-the-escape-hatch`).

      thinking ──chatted──┬─ tool calls, next is bash ─→ risk_check ─┬─ safe ──────→ executing
                          ├─ tool calls, other ───────→ executing   ├─ review/abstain → ask_human
                          ├─ no tool calls, edited ───→ verifying   └─ forbidden ─→ thinking (told)
                          └─ no tool calls ───────────→ answered
      executing ──tool_done──→ next call (risk_check | executing) | thinking
                               | verifying or answered (step limit)
      verifying ──verified──┬─ passed ─────────────────────→ answered
                            ├─ failed, fixes left ─────────→ thinking (told the output)
                            └─ failed, none left or stopped → answered (with the failure noted)
      ask_human ──approved──→ executing · ──denied──→ thinking (told)

  One run is one user turn. The session (`Xeito.Session`) keeps the conversation and passes the
  earlier messages in; the run adds the prompt, the model's messages and the tool results, and
  ends in `answered` with `ctx.answer` and `ctx.turn` (the full message list of the turn,
  system prompt first).

  **Verifying.** With `verify` (the project's check command, e.g. `mix ci`), a turn that edited
  files (`write`/`edit`) does not end on the model's word: the checks run first. If they fail,
  the model is shown the output and may fix it (twice at most); a turn that still fails, or that
  stopped at the step limit, ends with the failure stated in the answer. So "it compiles" means
  the code that actually runs was checked.

  The tool calls a model makes are *proposals*: each becomes an effect (`Xeito.Tools`), `bash`
  passes the `Risk` decision first, and invalid calls are answered with an error message rather
  than executed. `max_steps` (default 25) bounds the model turns per run.

  Input: `%{cwd: path, prompt: text, messages: [earlier messages], system: text, max_steps: n}`,
  optionally `verify: command` (see above),
  optionally `skills: [skill]` (`Xeito.Skills`, adds the `skill` tool) and `tools: false` (a plain
  answer with no tools, which streams sooner).
  """

  use Xeito.Machine, version: "0.2.0"

  alias Xeito.{Effect, Tools}

  @human_timeout 86_400_000
  @verify_timeout 900_000
  @max_fixes 2
  @output_tail 4_000

  initial :thinking

  state :thinking, entry: :ask_model, timeout: 900_000 do
    on :chatted, to: :failed, guard: :chat_error?, action: :record_error
    on :chatted, to: :verifying, guard: :calls_at_limit_edited?, action: :record_calls_and_stop
    on :chatted, to: :answered, guard: :calls_at_limit?, action: :record_calls_and_stop
    on :chatted, to: :risk_check, guard: :calls_next_risky?, action: :queue_calls
    on :chatted, to: :executing, guard: :calls_next_safe?, action: :queue_calls
    on :chatted, to: :thinking, guard: :only_invalid_calls?, action: :queue_calls
    on :chatted, to: :verifying, guard: :edited?, action: :record_answer
    on :chatted, to: :answered, action: :record_answer
  end

  state :risk_check do
    decide(Xeito.Decisions.Risk, input: :risk_input)
    on {:decided, :safe}, to: :executing
    on {:decided, :review}, to: :ask_human
    on {:decided, :abstain}, to: :ask_human
    on {:decided, :forbidden}, to: :answered, guard: :step_limit?, action: :forbid_and_stop
    on {:decided, :forbidden}, to: :thinking, action: :forbid
  end

  state :executing, entry: :run_tool, timeout: 900_000 do
    on :tool_done, to: :risk_check, guard: :next_risky?, action: :record_result
    on :tool_done, to: :executing, guard: :next_safe?, action: :record_result
    on :tool_done, to: :verifying, guard: :step_limit_edited?, action: :record_result_and_stop
    on :tool_done, to: :answered, guard: :step_limit?, action: :record_result_and_stop
    on :tool_done, to: :thinking, action: :record_result
  end

  state :verifying, entry: :run_checks, timeout: @verify_timeout do
    on :verified, to: :answered, guard: :checks_passed?, action: :record_checks
    on :verified, to: :thinking, guard: :can_fix?, action: :report_failure
    on :verified, to: :answered, action: :record_checks
  end

  state :ask_human, timeout: {@human_timeout, :denied} do
    on :approved, to: :executing
    on :denied, to: :answered, guard: :step_limit?, action: :deny_and_stop
    on :denied, to: :thinking, action: :deny
  end

  final :answered
  final :failed

  @default_system """
  You are a coding assistant working in a software project. Use the tools to inspect and change
  the project: read, write, edit (exact replacement) and bash (runs in the project root). Keep
  answers short. When the task is done, answer without calling a tool.
  """

  @doc "The default system prompt (the session adds project context such as `AGENTS.md`)."
  @spec default_system() :: String.t()
  def default_system, do: @default_system

  # --- entry functions ---------------------------------------------------------------------

  @doc false
  def ask_model(ctx) do
    [Effect.chat(messages(ctx), tools: Tools.names_for(ctx))]
  end

  @doc false
  def run_checks(ctx),
    do: [Effect.bash(ctx.verify, cwd: ctx.cwd, timeout: @verify_timeout, reply: :verified)]

  @doc false
  def run_tool(%{current: call} = ctx) do
    {:ok, effect} = Tools.to_effect(call, ctx)
    [effect]
  end

  # The system prompt and the prompt are added on the first turn only.
  defp messages(%{turn: [_ | _] = turn}), do: turn

  defp messages(ctx) do
    system = %{role: "system", content: Map.get(ctx, :system, @default_system)}
    [system | Map.get(ctx, :messages, [])] ++ [%{role: "user", content: ctx.prompt}]
  end

  # --- guards ------------------------------------------------------------------------------

  @doc false
  def chat_error?(_ctx, message), do: Map.has_key?(message, :error)

  @doc false
  def calls_next_risky?(ctx, message), do: next_is?(valid(message, ctx), true)

  @doc false
  def calls_next_safe?(ctx, message), do: next_is?(valid(message, ctx), false)

  @doc false
  def only_invalid_calls?(ctx, message),
    do: Map.get(message, :tool_calls, []) != [] and valid(message, ctx) == []

  # The model asks for tools on its last allowed turn: stop instead of running them.
  @doc false
  def calls_at_limit?(ctx, message),
    do: Map.get(message, :tool_calls, []) != [] and Map.get(ctx, :steps, 0) + 1 >= max_steps(ctx)

  @doc false
  def next_risky?(ctx, _result), do: next_is?(ctx.pending, true)

  @doc false
  def next_safe?(ctx, _result), do: next_is?(ctx.pending, false)

  @doc false
  def step_limit?(ctx, _data), do: Map.get(ctx, :steps, 0) >= max_steps(ctx)

  # Edits made in this turn and a check command to verify them with. `edited` is set when a
  # write or edit succeeds; the guard also counts the result arriving now.
  @doc false
  def edited?(ctx, _data), do: verify?(ctx) and Map.get(ctx, :edited, false)

  @doc false
  def calls_at_limit_edited?(ctx, message),
    do: calls_at_limit?(ctx, message) and edited?(ctx, message)

  @doc false
  def step_limit_edited?(ctx, result),
    do: step_limit?(ctx, result) and verify?(ctx) and (ctx[:edited] || edit_done?(ctx, result))

  @doc false
  def checks_passed?(_ctx, result), do: result.exit_status == 0

  @doc false
  def can_fix?(ctx, _result),
    do:
      not Map.get(ctx, :stopped, false) and Map.get(ctx, :fixes, 0) < @max_fixes and
        Map.get(ctx, :steps, 0) < max_steps(ctx)

  defp verify?(ctx), do: is_binary(ctx[:verify]) and ctx.verify != ""

  defp edit_done?(%{current: %{name: name}}, %{ok: true}) when name in ["write", "edit"], do: true
  defp edit_done?(_ctx, _result), do: false

  defp max_steps(ctx), do: Map.get(ctx, :max_steps, 25)

  defp next_is?([call | _], risky), do: Tools.risky?(call) == risky
  defp next_is?([], _risky), do: false

  defp valid(message, ctx) do
    for call <- Map.get(message, :tool_calls, []),
        match?({:ok, _}, Tools.to_effect(call, ctx)),
        do: call
  end

  # --- actions -----------------------------------------------------------------------------

  @doc false
  def queue_calls(ctx, message) do
    calls = Map.get(message, :tool_calls, [])
    {valid, invalid} = Enum.split_with(calls, &match?({:ok, _}, Tools.to_effect(&1, ctx)))

    errors =
      for call <- invalid do
        {:error, reason} = Tools.to_effect(call, ctx)
        tool_message(call, "error: " <> reason)
      end

    ctx
    |> put_turn([assistant_message(message) | errors])
    |> Map.update(:steps, 1, &(&1 + 1))
    |> add_tokens(message)
    |> advance(valid)
  end

  @doc false
  def record_answer(ctx, message) do
    ctx
    |> put_turn([assistant_message(message)])
    |> Map.update(:steps, 1, &(&1 + 1))
    |> add_tokens(message)
    |> Map.put(:answer, Map.get(message, :content, ""))
  end

  @doc false
  def record_calls_and_stop(ctx, message) do
    ctx
    |> put_turn([assistant_message(message)])
    |> Map.update(:steps, 1, &(&1 + 1))
    |> add_tokens(message)
    |> advance([])
    |> stop()
  end

  @doc false
  def record_error(ctx, message), do: Map.put(ctx, :error, message.error)

  @doc false
  def record_result(ctx, result) do
    ctx
    |> Map.update(:edited, edit_done?(ctx, result), &(&1 or edit_done?(ctx, result)))
    |> put_turn([tool_message(ctx.current, Tools.result_text(result))])
    |> advance(ctx.pending)
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

  # The model sees the failing output as the user's reply, and gets another chance.
  @doc false
  def report_failure(ctx, result) do
    text = """
    The project's checks (`#{ctx.verify}`) fail after your edits, exit status #{result.exit_status}.
    Fix the cause, or say why it cannot be fixed. Output (tail):
    #{tail(result.output)}
    """

    ctx
    |> put_turn([%{role: "user", content: text}])
    |> Map.update(:fixes, 1, &(&1 + 1))
    |> Map.delete(:answer)
  end

  defp tail(output) when byte_size(output) > @output_tail,
    do: "…" <> binary_part(output, byte_size(output) - @output_tail, @output_tail)

  defp tail(output), do: output

  @doc false
  def forbid(ctx, _result),
    do: refuse(ctx, "blocked: the Risk decision classified this command as forbidden")

  @doc false
  def forbid_and_stop(ctx, result), do: ctx |> forbid(result) |> stop()

  @doc false
  def deny(ctx, _data), do: refuse(ctx, "denied: the user did not approve this command")

  @doc false
  def deny_and_stop(ctx, data), do: ctx |> deny(data) |> stop()

  @doc false
  def risk_input(%{current: %{arguments: %{"command" => command}}}), do: %{command: command}

  # A refused call is reported to the model, and the rest of that batch is skipped.
  defp refuse(ctx, reason) do
    skipped =
      for call <- ctx.pending, do: tool_message(call, "skipped: an earlier call was refused")

    ctx
    |> put_turn([tool_message(ctx.current, reason) | skipped])
    |> advance([])
  end

  defp stop(ctx) do
    ctx
    |> Map.put(:answer, "Stopped after #{ctx.steps} model turns (max_steps).")
    |> Map.put(:stopped, true)
  end

  defp advance(ctx, [next | rest]), do: Map.merge(ctx, %{current: next, pending: rest})
  defp advance(ctx, []), do: Map.merge(ctx, %{current: nil, pending: []})

  defp put_turn(ctx, new_messages) do
    Map.put(ctx, :turn, messages(ctx) ++ new_messages)
  end

  defp add_tokens(ctx, message) do
    ctx
    |> Map.update(
      :tokens_in,
      Map.get(message, :tokens_in, 0),
      &(&1 + Map.get(message, :tokens_in, 0))
    )
    |> Map.update(
      :tokens_out,
      Map.get(message, :tokens_out, 0),
      &(&1 + Map.get(message, :tokens_out, 0))
    )
  end

  defp assistant_message(message) do
    calls =
      for c <- Map.get(message, :tool_calls, []),
          do: %{function: %{name: c.name, arguments: c.arguments}}

    %{role: "assistant", content: Map.get(message, :content, "")}
    |> then(&if(calls == [], do: &1, else: Map.put(&1, :tool_calls, calls)))
  end

  defp tool_message(call, text), do: %{role: "tool", tool_name: call.name, content: text}
end
