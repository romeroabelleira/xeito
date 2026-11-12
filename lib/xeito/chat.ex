defmodule Xeito.Chat do
  @moduledoc """
  Streaming chat-model client with native tool calling, used by the chat machine and delegated sub-tasks.

    * tier (`tier/1`): option `tier:`, else `config :xeito, :chat_tier`, else `:local`
    * the call is made by the tier's backend (`Xeito.Backends.chat/5`); one that cannot chat is an error
    * on an off-box tier each call must pass `Xeito.Allowance.verdict/1` (run budget `max_usd:`,
      key allowance) and its cost is charged to `run:` and the key; a backend that neither
      reports nor prices its calls (`Xeito.Backends.spend/1`) is refused there
    * calls go through the tier's capacity queue (`Xeito.Tiers.Queue`)
    * thinking is off unless `cfg[:think]`; `cfg[:format]`, a JSON Schema, constrains the answer
    * the reply says its `tier`

  Each streamed text chunk goes to `on_delta`; the call returns the complete message:

      {:ok, %{content: "...", tool_calls: [%{name: "bash", arguments: %{...}}],
              model: "...", tier: :local, tokens_in: 812, tokens_out: 64, latency_ms: 2140,
              first_token_ms: 410}}
  """

  alias Xeito.Allowance
  alias Xeito.Backends
  alias Xeito.Budget
  alias Xeito.Chat.Message
  alias Xeito.Chat.Window
  alias Xeito.Policy
  alias Xeito.Tiers
  alias Xeito.Tiers.Queue

  @type message :: Message.t()

  @doc "Runs one chat turn. `tools` are OpenAI-style function specs (see `Xeito.Tools.specs/0`)."
  @spec complete([Message.t()], [map()], keyword(), (String.t() -> any())) ::
          {:ok, Message.reply()} | {:error, term()}
  def complete(messages, tools, overrides \\ [], on_delta \\ fn _ -> :ok end) do
    tier = tier(overrides)

    case Tiers.config(tier, Keyword.delete(overrides, :tier)) do
      nil -> {:error, :chat_model_unavailable}
      cfg -> chat(Tiers.backend(tier, cfg), tier, {messages, tools}, cfg, on_delta)
    end
  end

  @doc "The chat tier: the session's choice (`tier:`), else the configured one, else `:local`."
  @spec tier(keyword()) :: atom()
  def tier(overrides), do: Keyword.get_lazy(overrides, :tier, fn -> Application.get_env(:xeito, :chat_tier, :local) end)

  # A tier on this machine costs nothing; an off-box one is planned and charged.
  defp chat(backend, tier, request, cfg, on_delta) do
    if tier in Tiers.off_box(),
      do: remote(Backends.spend(backend), backend, tier, request, cfg, on_delta),
      else: local(backend, tier, request, cfg, on_delta)
  end

  defp local(backend, tier, {messages, tools}, cfg, on_delta) do
    with {:ok, message} <- Queue.run(tier, fn -> Backends.chat(backend, messages, tools, cfg, on_delta) end),
         do: {:ok, Map.put(message, :tier, tier)}
  end

  # Off the machine, a call whose cost nothing reports or prices cannot be held to the run's budget.
  defp remote(:none, backend, _tier, _request, _cfg, _on_delta), do: {:error, {:unpriced_backend, backend}}

  # A hosted model: the call is planned against the run's budget and the key's allowance, then charged.
  defp remote(_spend, backend, tier, {messages, tools}, cfg, on_delta) do
    cfg = Keyword.put(cfg, :backend, backend)
    price = Allowance.model_price(cfg)
    cfg = Keyword.put_new(cfg, :max_tokens, answer_limit(price))

    with :ok <- plan(messages, tools, cfg, price) do
      tier
      |> Queue.run(fn -> Backends.chat(backend, messages, tools, cfg, on_delta) end)
      |> charge(tier, cfg)
    end
  end

  # The longest answer asked for: 8192 tokens, or less where the model allows less.
  defp answer_limit(%{output: output}) when is_integer(output), do: min(output, 8192)
  defp answer_limit(_price), do: 8192

  defp plan(messages, tools, cfg, price) do
    tokens = Window.estimate(messages, Window.default_chars_per_token()) + div(byte_size(JSON.encode!(tools)), 3)

    Allowance.verdict(%{
      run_spent: if(cfg[:run], do: Budget.get(cfg[:run], :usd), else: 0),
      run_max: Keyword.get_lazy(cfg, :max_usd, fn -> Policy.effective().max_usd_per_run end),
      left: Allowance.remaining(cfg),
      worst: Allowance.worst_case(price, tokens, cfg[:max_tokens])
    })
  end

  defp charge({:ok, message}, tier, cfg) do
    Allowance.spent(cfg, message.usd)
    if cfg[:run], do: Budget.add(cfg[:run], :usd, message.usd)
    {:ok, Map.put(message, :tier, tier)}
  end

  defp charge(error, _tier, _cfg), do: error
end
