defmodule Xeito.Session.History do
  @moduledoc """
  A finished turn's answer and the conversation history it leaves, also rebuilt from the log on resume.

  The history is the session state's `history`: messages without the system prompt, at most 80,
  trimmed back to the last 60 with a leading summary of earlier turns kept first. A chat turn
  replaces it with its own messages (a halted one without unanswered tool calls); a shell
  command adds a note in the user's voice; any other machine adds the prompt and its answer.
  """

  alias Xeito.Chat.Window
  alias Xeito.Log
  alias Xeito.Machines.Chat
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Machines.Shell
  alias Xeito.Run
  alias Xeito.Session
  alias Xeito.Session.Notify

  # Trimmed with slack (80 back to 60) so the first message, which keys the log's chain, rarely changes.
  @max_history 80
  @trimmed_history 60

  @halted "Halted by the user."

  @doc "The answer of a halted turn."
  @spec halted() :: String.t()
  def halted, do: @halted

  @doc "Rebuilds the turn count and history from the session's logged turns; an unfinished run is reported, not re-executed."
  @spec restore(Session.state()) :: Session.state()
  def restore(s) do
    turns =
      s.log
      |> Log.query(
        "SELECT ocel_source_id FROM object_object WHERE ocel_target_id = ?1 AND ocel_qualifier = 'part_of'",
        [s.id]
      )
      |> Enum.flat_map(fn [run] ->
        case Regex.run(~r{/t(\d+)$}, run) do
          [_, n] -> [{String.to_integer(n), run}]
          nil -> []
        end
      end)
      |> Enum.sort()

    Enum.reduce(turns, s, &restore_turn/2)
  end

  defp restore_turn({n, run}, s) do
    s = %{s | turn: max(s.turn, n)}

    with [{_, "run_started", {:run_started, machine, _version, input}} | _] <-
           Log.read_run(s.log, run),
         {:ok, result} <- Run.result(s.log, run) do
      s = %{s | machine: machine, prompt: Map.get(input, :request) || Map.get(input, :prompt)}

      %{
        s
        | history: remember(s, result, answer(machine, result)),
          machine: nil,
          prompt: nil,
          unfinished: stopped?(result)
      }
    else
      _ ->
        %{
          s
          | history: s.history ++ [%{role: "assistant", content: "(turn #{n} was interrupted)"}]
        }
    end
  end

  @doc "The answer a finished run of `machine` gives the user."
  @spec answer(module(), map()) :: String.t()
  def answer(_machine, %{status: :halted}), do: @halted
  def answer(Chat, %{ctx: ctx}), do: Map.get(ctx, :answer) || ctx |> Map.get(:error) |> to_text()

  def answer(FixFailingTest, result), do: fix_failing_answer(result)
  def answer(Shell, %{ctx: %{cmd: cmd, exit_status: status}}), do: "`#{cmd}` exited #{status}"

  def answer(machine, result), do: ended(machine, result)

  defp ended(machine, %{state: state} = result) do
    ctx = Map.get(result, :ctx, %{})

    Map.get(ctx, :answer) ||
      ctx |> Map.get(:error) |> to_text() |> default("#{inspect(machine)} ended in #{state}")
  end

  defp fix_failing_answer(%{state: :done, ctx: ctx}) when not is_map_key(ctx, :last_failure),
    do:
      "The tests pass (#{Map.get(ctx, :test_cmd, "the test suite")}): there is no failing test to fix. " <>
        "To write a new test, ask for it without saying it fails, or use /machine chat <request>."

  defp fix_failing_answer(%{state: state, ctx: ctx}), do: "fix_failing_test ended in #{state}" <> fix_answer(ctx)

  defp fix_answer(ctx) do
    case get_in(ctx, [:fix, :answer]) do
      nil -> ""
      fix -> ": " <> fix
    end
  end

  defp default("", fallback), do: fallback
  defp default(text, _fallback), do: text

  defp to_text(nil), do: ""
  defp to_text(text) when is_binary(text), do: text
  # Reasons from `Xeito.Allowance` are written for the user.
  defp to_text({kind, text}) when kind in [:budget, :allowance, :quota, :context_overflow] and is_binary(text), do: text
  defp to_text(other), do: inspect(other)

  @doc "Whether a run stopped short: halted, or at its step limit."
  @spec stopped?(map()) :: boolean()
  def stopped?(%{status: :halted}), do: true
  def stopped?(%{ctx: ctx}), do: Map.get(ctx, :stopped, false) == true
  def stopped?(_result), do: false

  @doc "The history after the turn of the state's `machine` and `prompt` ended with `result` and `answer`."
  @spec remember(Session.state(), map(), String.t()) :: [map()]
  def remember(%{machine: Chat}, %{status: :halted, ctx: %{turn: [_system | messages]}}, answer),
    do: trim(settled(messages) ++ [%{role: "assistant", content: "(#{answer})"}])

  def remember(%{machine: Chat}, %{ctx: %{turn: [_system | messages]}}, _answer), do: trim(messages)

  # A note in the user's voice, not an exchange.
  def remember(%{machine: Shell} = s, %{ctx: ctx}, _answer),
    do: trim(s.history ++ [%{role: "user", content: shell_note(ctx)}])

  def remember(s, _result, answer) do
    trim(s.history ++ [%{role: "user", content: s.prompt || ""}, %{role: "assistant", content: answer}])
  end

  defp shell_note(%{cmd: cmd, report: report}), do: "(I ran `#{cmd}` in the workspace:\n```\n#{report}\n```)"
  defp shell_note(%{cmd: cmd}), do: "(I ran `#{cmd}` in the workspace and stopped it before it finished.)"

  @doc "The messages without a trailing tool call left unanswered, so the next request is well-formed."
  @spec settled([map()]) :: [map()]
  def settled(messages) do
    with i when i != nil <- Enum.find_index(Enum.reverse(messages), &calls?/1),
         {before, [call | rest]} <- Enum.split(messages, length(messages) - 1 - i),
         true <- Enum.count(rest, &(&1.role == "tool")) < length(call.tool_calls) do
      before
    else
      _ -> messages
    end
  end

  defp calls?(message), do: match?(%{role: "assistant", tool_calls: [_ | _]}, message)

  @doc "The history window: past 80 messages, the last 60, with a leading summary of earlier turns kept first."
  @spec trim([map()]) :: [map()]
  def trim(messages) when length(messages) > @max_history do
    {pinned, rest} = Enum.split_while(messages, &Window.summary?/1)
    pinned ++ Enum.take(rest, length(pinned) - @trimmed_history)
  end

  def trim(messages), do: messages

  @doc "Emits a notice when the model server cut the turn's prompt from the front."
  @spec warn_truncated(Session.state(), map()) :: Session.state()
  def warn_truncated(s, %{ctx: %{context_truncated: true}}),
    do:
      Notify.notice(
        s,
        "the model server cut this turn's prompt from the front (the system prompt was lost): " <>
          "set XEITO_LOCAL_CONTEXT to the model's context window"
      )

  def warn_truncated(s, _result), do: s
end
