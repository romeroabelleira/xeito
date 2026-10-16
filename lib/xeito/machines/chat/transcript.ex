defmodule Xeito.Machines.Chat.Transcript do
  @moduledoc """
  How a chat turn records its steps in `ctx.turn`: the model's replies, tool results and notes, as chat messages.

  - `put_turn/2` appends messages to the turn so far (`Xeito.Machines.Chat.Request.messages/1`);
    `put_reply/2` appends a model reply, after the steers its request carried, and passes the
    steers on (`Xeito.Machines.Chat.Steering.delivered/1`).
  - `assistant/1` is a reply as an assistant message, with its tool calls; `tool/2` and
    `tool/3` a tool result. A result with a `ref` also says what it was (`about:`, the text of
    its stub if it is elided later) and, for a whole read of a project file, `read:` its path.
  - `add_tokens/2` counts a reply's tokens; its `tokens_in` calibrates the characters per token
    against the request as sent, and notices a prompt the server cut (`ctx.context_truncated`).
    It relies on `ctx` still being as the request was sent.
  """

  alias Xeito.Chat.Window
  alias Xeito.Machines.Chat.Elision
  alias Xeito.Machines.Chat.Request
  alias Xeito.Machines.Chat.Steering
  alias Xeito.Tools.Shape

  @doc "Appends messages to the turn so far."
  @spec put_turn(map(), [map()]) :: map()
  def put_turn(ctx, new_messages), do: Map.put(ctx, :turn, Request.messages(ctx) ++ new_messages)

  @doc "Appends a model reply (and what goes with it) after the steers its request carried."
  @spec put_reply(map(), [map()]) :: map()
  def put_reply(ctx, new_messages) do
    ctx
    |> put_turn(Steering.messages(ctx) ++ new_messages)
    |> Steering.delivered()
  end

  @doc "Counts a reply's tokens and measures the request it answered."
  @spec add_tokens(map(), map()) :: map()
  def add_tokens(ctx, message) do
    tokens_in = Map.get(message, :tokens_in, 0)
    tokens_out = Map.get(message, :tokens_out, 0)

    ctx
    |> Map.update(:tokens_in, tokens_in, &(&1 + tokens_in))
    |> Map.update(:tokens_out, tokens_out, &(&1 + tokens_out))
    |> measure_window(tokens_in)
  end

  defp measure_window(ctx, 0), do: ctx

  defp measure_window(ctx, tokens_in) do
    sent = ctx |> Request.outgoing() |> Elision.elide() |> Window.characters()

    ctx
    |> Map.put(:chars_per_token, Window.calibrate(sent, tokens_in))
    |> Map.put(:context_truncated, ctx[:context_truncated] == true or Window.truncated?(tokens_in, ctx[:context]))
  end

  @doc "A model reply as an assistant message, with its tool calls."
  @spec assistant(map()) :: map()
  def assistant(message) do
    calls =
      for c <- Map.get(message, :tool_calls, []),
          do: %{function: %{name: c.name, arguments: c.arguments}}

    then(
      %{role: "assistant", content: Map.get(message, :content, "")},
      &if(calls == [], do: &1, else: Map.put(&1, :tool_calls, calls))
    )
  end

  @doc "A tool message answering `call` with `text`."
  @spec tool(map(), String.t()) :: map()
  def tool(call, text), do: %{role: "tool", tool_name: call.name, content: text}

  @doc "A tool message for the result of `call`; with a `ref`, also what it was and any whole read."
  @spec tool(map(), String.t(), map()) :: map()
  def tool(call, text, %{ref: ref} = result) do
    call
    |> tool(text)
    |> Map.merge(%{ref: ref, about: about(call)})
    |> Map.merge(whole_read(call, result))
  end

  def tool(call, text, _result), do: tool(call, text)

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

  @doc "The text of a model reply, or a note that the model ended the turn without one."
  @spec answer(map()) :: String.t()
  def answer(message) do
    case message |> Map.get(:content, "") |> to_string() |> String.trim() do
      "" -> "(The model ended this turn without an answer.)"
      text -> text
    end
  end
end
