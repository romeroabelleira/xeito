defmodule Xeito.Machines.Chat.Request do
  @moduledoc """
  The model requests of a chat turn: the messages they send, and their fit into the context window.

  - `messages/1` is the turn so far: `ctx.turn` once it has started, else the system prompt
    (`ctx.system`, or `default_system/0`), the earlier conversation (`ctx.messages`) and the
    user's prompt, with the skill chosen for it (`ctx.suggested_skill`) suggested at its end.
  - `chat/3` elides old tool output (`Xeito.Machines.Chat.Elision`) and fits the messages into
    `window/1` (`Xeito.Chat.Window.fit/2`), keeping the current turn. A request that cannot fit
    is not sent: its `chat` effect carries the reason as `error:`, and the turn fails.
  - `window/1` is the request budget: the context (`ctx.context`, default 32k tokens) less 8k
    kept for the reply, estimated at the turn's measured characters per token.
  """

  alias Xeito.Chat.Window
  alias Xeito.Effect
  alias Xeito.Machines.Chat.Elision
  alias Xeito.Machines.Chat.Steering

  @default_context 32_768
  @output_reserve 8_192

  @default_system """
  You are a coding assistant working in a software project. Use the tools to inspect and change
  the project: read, write, edit (exact replacement) and bash (runs in the project root). Keep
  answers short. When the task is done, answer without calling a tool.
  """

  @doc "The default system prompt; the session adds project context."
  @spec default_system() :: String.t()
  def default_system, do: @default_system

  @doc "The turn so far, system prompt first."
  @spec messages(map()) :: [map()]
  def messages(%{turn: [_ | _] = turn}), do: turn

  def messages(ctx) do
    system = %{role: "system", content: Map.get(ctx, :system, @default_system)}
    [system | Map.get(ctx, :messages, [])] ++ [%{role: "user", content: ctx.prompt <> skill_hint(ctx[:suggested_skill])}]
  end

  defp skill_hint(nil), do: ""

  defp skill_hint(skill),
    do:
      "\n\n(A skill may fit this request; if it does, load it with the skill tool before you start: " <>
        "#{skill.name}: #{skill.description})"

  @doc "What the next model request sends before it is fitted: the turn so far and the steers it carries."
  @spec outgoing(map()) :: [map()]
  def outgoing(ctx), do: messages(ctx) ++ Steering.messages(ctx)

  @doc "The `chat` effect for `messages`, elided and fitted into the window, or carrying why they cannot fit."
  @spec chat(map(), [map()], keyword()) :: Effect.t()
  def chat(ctx, messages, opts) do
    window = Keyword.put(window(ctx), :keep_from, 1 + length(Map.get(ctx, :messages, [])))

    case messages |> Elision.elide() |> Window.fit(window) do
      {:ok, fitted, _report} -> Effect.chat(fitted, opts)
      {:error, reason} -> Effect.chat(messages, Keyword.put(opts, :error, reason))
    end
  end

  @doc "The request budget for `Xeito.Chat.Window`: tokens and characters per token."
  @spec window(map()) :: keyword()
  def window(ctx),
    do: [
      budget: (ctx[:context] || @default_context) - @output_reserve,
      chars_per_token: Map.get(ctx, :chars_per_token, Window.default_chars_per_token())
    ]

  @doc """
  `ctx` with a window three quarters the size of the request just sent (as fitted), plus the
  reply's share, and `shrunk: true`: the model said the request was longer than its window.
  """
  @spec shrink(map()) :: map()
  def shrink(ctx) do
    [budget: budget, chars_per_token: cpt] = window(ctx)
    sent = min(Window.estimate(Elision.elide(outgoing(ctx)), cpt), budget)
    ctx |> Map.put(:context, div(sent * 3, 4) + @output_reserve) |> Map.put(:shrunk, true)
  end

  @doc "The user message that asks a stopped turn for its report, without tools, saying why it stopped."
  @spec wrap_up(map()) :: map()
  def wrap_up(ctx) do
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
end
