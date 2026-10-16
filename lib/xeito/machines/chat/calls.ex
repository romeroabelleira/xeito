defmodule Xeito.Machines.Chat.Calls do
  @moduledoc """
  The tool calls of a chat turn's model replies: which may run, and the bookkeeping that catches a model repeating itself.

  - `sort/2` splits a reply's calls into those that run and those refused with a reason: a call
    `Xeito.Tools.to_effect/2` rejects, or an exact repeat (same name and arguments) of a call
    made in this turn since its last edit (`ctx.seen`), answered with the earlier result when
    it is known (`ctx.results`). Repeats within one reply count too.
  - `remember/3` records a reply: its valid calls as seen, the streak of replies with no valid
    call (`ctx.invalid_streak`), and how it opened (`ctx.openings`). `stuck_note/2` is a nudge
    for a reply opening with the same sentence as two earlier ones.
  - `remember_result/2` keeps a call's result for repeats; `forget/1` allows repeats again
    after an edit (`edit_done?/2`).
  """

  alias Xeito.Tools

  @type rejected :: {map(), String.t()}

  @doc "A reply's calls as `{valid, [{call, reason}]}`, in order."
  @spec sort(map(), map()) :: {[map()], [rejected()]}
  def sort(message, ctx) do
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

  @doc "The calls of a reply that may run."
  @spec valid(map(), map()) :: [map()]
  def valid(message, ctx), do: message |> sort(ctx) |> elem(0)

  @doc "Whether there is a next call and its risk (`Xeito.Tools.risky?/1`) is `risky`."
  @spec next_is?([map()], boolean()) :: boolean()
  def next_is?([call | _], risky), do: Tools.risky?(call) == risky
  def next_is?([], _risky), do: false

  @doc "Records a reply whose valid calls are `valid`: the calls seen, the invalid streak, its opening."
  @spec remember(map(), map(), [map()]) :: map()
  def remember(ctx, message, valid) do
    ctx
    |> Map.update(
      :seen,
      Enum.map(valid, &{&1.name, &1.arguments}),
      &(Enum.map(valid, fn c -> {c.name, c.arguments} end) ++ &1)
    )
    |> Map.put(:invalid_streak, if(valid == [], do: Map.get(ctx, :invalid_streak, 0) + 1, else: 0))
    |> Map.update(:openings, [opening(message)], &[opening(message) | &1])
  end

  @doc "A nudge for a reply that opens like two earlier ones in the turn, or nothing."
  @spec stuck_note(map(), map()) :: [map()]
  def stuck_note(ctx, message) do
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

  @doc "The nudge for a second step of only repeated or invalid calls in a turn that changed nothing."
  @spec nudge() :: map()
  def nudge,
    do: %{
      role: "user",
      content:
        "You already have the results you need, and repeating calls will end this turn. " <>
          "Act on them now: make the change you planned, give your answer, or say what blocks you."
    }

  @doc "Keeps the result of the current call, to answer a repeat of it."
  @spec remember_result(map(), map()) :: map()
  def remember_result(ctx, result) do
    key = {ctx.current.name, ctx.current.arguments}
    Map.update(ctx, :results, %{key => Tools.result_text(result)}, &Map.put(&1, key, Tools.result_text(result)))
  end

  @doc "Forgets the calls seen and their results: after an edit, repeats are allowed again."
  @spec forget(map()) :: map()
  def forget(ctx), do: Map.merge(ctx, %{seen: [], results: %{}})

  @doc "Whether the current call was a write or edit that succeeded."
  @spec edit_done?(map(), map()) :: boolean()
  def edit_done?(%{current: %{name: name}}, %{ok: true}) when name in ["write", "edit"], do: true
  def edit_done?(_ctx, _result), do: false
end
