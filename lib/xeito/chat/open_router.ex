defmodule Xeito.Chat.OpenRouter do
  @moduledoc """
  Streamed chat with tool calls on a hosted model through OpenRouter's chat completions API.

  The wire format is `Xeito.Chat.OpenAI`'s; this module adds what is OpenRouter's.

  The request (`body/3`):

    * `provider`: `require_parameters`, `data_collection: "deny"`, `zdr` (default true), and
      `cfg[:providers]` as `only`.
    * `max_tokens` (default 8192), which also bounds the cost `Xeito.Allowance` plans for.
    * `cache_control` for `anthropic/` models.
    * `reasoning` (the tier's effort, else `think:` as `enabled`) and `temperature` only when set;
      with `require_parameters`, a parameter no endpoint takes leaves no endpoint.
    * `response_format`: a strict JSON Schema, when `format:` sets one.

  The result has the shape of `Xeito.Chat.complete/4`'s, plus `usd`, `cached_tokens` and
  `served_by` (`openrouter:<model>@<provider>`).
  """

  alias Xeito.Chat.Message
  alias Xeito.Chat.OpenAI

  @max_tokens 8192

  @doc "Runs one chat turn on the tier configured by `cfg`."
  @spec complete([Message.t()], [map()], keyword(), (String.t() -> any())) :: {:ok, Message.reply()} | {:error, term()}
  def complete(messages, tools, cfg, on_delta) do
    OpenAI.request(body(messages, tools, cfg), cfg, on_delta,
      name: :openrouter,
      headers: [{"x-openrouter-title", "Xeito"}]
    )
  end

  @doc false
  def body(messages, tools, cfg) do
    model = Keyword.fetch!(cfg, :model)

    %{
      model: model,
      messages: OpenAI.messages(messages),
      stream: true,
      usage: %{include: true},
      max_tokens: Keyword.get(cfg, :max_tokens, @max_tokens),
      provider: provider(cfg)
    }
    |> OpenAI.put_if(:tools, tools, tools != [])
    |> OpenAI.put_if(:cache_control, %{type: "ephemeral"}, String.starts_with?(model, "anthropic/"))
    |> OpenAI.put_if(:reasoning, reasoning(cfg), cfg[:reasoning] != nil or is_boolean(cfg[:think]))
    |> OpenAI.put_if(:temperature, cfg[:temperature], cfg[:temperature] != nil)
    |> OpenAI.put_if(:response_format, OpenAI.response_format(cfg[:format]), cfg[:format] != nil)
  end

  defp reasoning(cfg), do: if(cfg[:reasoning], do: %{effort: cfg[:reasoning]}, else: %{enabled: cfg[:think]})

  defp provider(cfg) do
    then(
      %{require_parameters: true, data_collection: "deny", zdr: Keyword.get(cfg, :zdr, true)},
      &if(cfg[:providers], do: Map.put(&1, :only, cfg[:providers]), else: &1)
    )
  end
end
