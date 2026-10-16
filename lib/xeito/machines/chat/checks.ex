defmodule Xeito.Machines.Chat.Checks do
  @moduledoc """
  The project's checks (`ctx.verify`) a chat turn runs after editing files, and what the model and the user are told when they fail.

  - `verify?/1`: the input names a non-empty check command.
  - `fix_prompt/2` tells the model the checks fail, the exit status, the model turns left for
    fixing (`Xeito.Machines.Chat.Limits.fix_turns_left/1`) and the output's tail (its shaped
    form if there is one, else its last 4,000 bytes).
  - `record/2` puts the outcome in `ctx.checks`; a failure is also noted in the answer.
  """

  alias Xeito.Machines.Chat.Limits

  @output_tail 4_000

  @doc "Whether the turn has a check command to run after edits."
  @spec verify?(map()) :: boolean()
  def verify?(ctx), do: is_binary(ctx[:verify]) and ctx.verify != ""

  @doc "The user message telling the model that the checks fail, with their output."
  @spec fix_prompt(map(), map()) :: map()
  def fix_prompt(ctx, result) do
    text = """
    The project's checks (`#{ctx.verify}`) fail after your edits, exit status #{result.exit_status}.
    Fix the cause, or say why it cannot be fixed. You have #{Limits.fix_turns_left(ctx)} more model turns for this. Output (tail):
    #{result[:shaped] || tail(result.output)}
    """

    %{role: "user", content: text}
  end

  defp tail(output) when byte_size(output) > @output_tail,
    do: "…" <> binary_part(output, byte_size(output) - @output_tail, @output_tail)

  defp tail(output), do: output

  @doc "Records the checks' outcome; a failure is noted in the answer."
  @spec record(map(), map()) :: map()
  def record(ctx, result) do
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
end
