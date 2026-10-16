defmodule Xeito.Machines.Chat.Steering do
  @moduledoc """
  The lines a user sends while a chat turn works (steers), held in the context until a model request carries them.

  A steer between model calls (`steer/2`, in `ctx.steers`) goes with the next request, as a user
  message (`messages/1`) after the turn so far, and into the turn just before that request's
  reply. A steer during a model call (`steer_late/2`, in `ctx.late_steers`) waits for the reply
  (`delivered/1`) and goes with the request after it. `undelivered/1` hands back what a turn
  ends with, oldest first.
  """

  @doc "Adds a line from the user while the turn works, for the next model request."
  @spec steer(map(), %{text: String.t()}) :: map()
  def steer(ctx, %{text: text}), do: Map.update(ctx, :steers, [text], &(&1 ++ [text]))

  @doc "Adds a line from the user during a model call, held until the reply arrives."
  @spec steer_late(map(), %{text: String.t()}) :: map()
  def steer_late(ctx, %{text: text}), do: Map.update(ctx, :late_steers, [text], &(&1 ++ [text]))

  @doc "The steers not yet given to the model, oldest first."
  @spec undelivered(map()) :: [String.t()]
  def undelivered(ctx), do: Map.get(ctx, :steers, []) ++ Map.get(ctx, :late_steers, [])

  @doc "The user messages the next model request carries for the steers."
  @spec messages(map()) :: [map()]
  def messages(ctx),
    do:
      for(text <- Map.get(ctx, :steers, []), do: %{role: "user", content: "(The user, while you were working:) " <> text})

  @doc "After a reply: the steers its request carried are delivered, the late ones go with the next."
  @spec delivered(map()) :: map()
  def delivered(ctx), do: ctx |> Map.put(:steers, Map.get(ctx, :late_steers, [])) |> Map.put(:late_steers, [])
end
