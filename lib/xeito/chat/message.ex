defmodule Xeito.Chat.Message do
  @moduledoc """
  The types of a chat conversation: its messages, the tool calls in them, and a model's reply.

  Messages are plain maps, in Ollama's form: a tool result follows the assistant message that
  called it, in order, and names the tool (`tool_name`). Besides the fields a model reads
  (`role`, `content`, `tool_calls`, `tool_name`), a message may carry Xeito's own bookkeeping,
  which backends strip before sending:

    * `ref`, `about`: a tool result that can be read back by its effect id, and what it was
      (`Xeito.Chat.Window.stub/1` replaces it with a one-line stub);
    * `read`: the path of a whole project file the result holds;
    * `summary`, `covers`: a summary standing for `covers` earlier messages.

  Maps rather than structs: conversations are stored in the log and in sessions as maps.
  """

  @typedoc "A tool call as a model proposed it: arguments decoded from JSON (`%{\"_raw\" => text}` if they were not)."
  @type tool_call :: %{name: String.t(), arguments: map()}

  @typedoc "A message of the conversation."
  @type t :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:tool_calls) => [%{function: tool_call()}],
          optional(:tool_name) => String.t(),
          optional(:ref) => String.t(),
          optional(:about) => String.t(),
          optional(:read) => Path.t(),
          optional(:summary) => true,
          optional(:covers) => pos_integer()
        }

  @typedoc """
  One model call's answer (`Xeito.Chat.complete/4`). A remote tier's reply also has `usd`
  (the cost OpenRouter reported), `cached_tokens`, `served_by` and `tier`.
  """
  @type reply :: %{
          required(:content) => String.t(),
          required(:tool_calls) => [tool_call()],
          required(:model) => String.t(),
          required(:tokens_in) => non_neg_integer(),
          required(:tokens_out) => non_neg_integer(),
          required(:latency_ms) => non_neg_integer(),
          required(:first_token_ms) => non_neg_integer() | nil,
          optional(:usd) => float(),
          optional(:cached_tokens) => non_neg_integer(),
          optional(:served_by) => String.t(),
          optional(:tier) => atom()
        }
end
