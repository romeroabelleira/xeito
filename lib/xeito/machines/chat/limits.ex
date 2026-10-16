defmodule Xeito.Machines.Chat.Limits do
  @moduledoc """
  How many model turns a chat turn may take, and how it stops when it runs out.

  - A turn has `ctx.max_steps` model turns (default 25). Once a failing check has been reported
    to the model (`ctx.fixing`), it has 4 more for fixes (`limit/1`), shared by all of them, and
    at most 2 fixes (`can_fix?/1`).
  - `at_limit?/1` holds once the steps taken reach the limit; `last_step?/1` when the reply now
    being recorded takes the last one.
  - `stop/2` ends the turn's work with a notice as its answer: `:limit` after the steps ran
    out, `:invalid` after the model kept making calls that could not run.
  """

  @max_fixes 2
  @fix_budget 4

  @doc "The model turns the input allows before any fix."
  @spec max_steps(map()) :: non_neg_integer()
  def max_steps(ctx), do: Map.get(ctx, :max_steps, 25)

  @doc "The model turns allowed now: `max_steps`, plus the fix budget once fixing."
  @spec limit(map()) :: non_neg_integer()
  def limit(ctx), do: max_steps(ctx) + if(ctx[:fixing], do: @fix_budget, else: 0)

  @doc "Whether the steps taken have reached the limit."
  @spec at_limit?(map()) :: boolean()
  def at_limit?(ctx), do: Map.get(ctx, :steps, 0) >= limit(ctx)

  @doc "Whether the reply being recorded takes the last step allowed."
  @spec last_step?(map()) :: boolean()
  def last_step?(ctx), do: Map.get(ctx, :steps, 0) + 1 >= limit(ctx)

  @doc "Whether another fix is allowed, also at the step limit: fixes have their own budget past it."
  @spec can_fix?(map()) :: boolean()
  def can_fix?(ctx), do: Map.get(ctx, :fixes, 0) < @max_fixes and Map.get(ctx, :steps, 0) < max_steps(ctx) + @fix_budget

  @doc "The model turns left for fixing."
  @spec fix_turns_left(map()) :: integer()
  def fix_turns_left(ctx), do: max_steps(ctx) + @fix_budget - Map.get(ctx, :steps, 0)

  @doc "Stops the turn's work, with a notice of why as its answer."
  @spec stop(map(), :limit | :invalid) :: map()
  def stop(ctx, reason \\ :limit) do
    notice =
      case reason do
        :limit -> "Stopped after #{ctx.steps} model turns (max_steps)."
        :invalid -> "Stopped: the model kept making tool calls that could not run."
      end

    Map.merge(ctx, %{answer: notice, stopped: true, stop_reason: reason})
  end
end
