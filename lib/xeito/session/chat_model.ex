defmodule Xeito.Session.ChatModel do
  @moduledoc """
  The session's chat tier (`/model`): which tiers can chat, what each holds, and the notices for switching.

  `Xeito.Session` keeps the choice in its chat options (`tier:`), which `Xeito.Chat` reads.
  A remote tier sends the conversation and every file the model reads to OpenRouter, so only a
  person chooses it (`/model`, or `XEITO_CHAT_TIER` for every session), never the model.
  """

  alias Xeito.Tiers

  @chat_tiers [:local, :remote, :remote_frontier]
  # A remote tier's window when `XEITO_<TIER>_CONTEXT` is not set.
  @remote_context 131_072

  @doc "The session's chat tier, from its chat options (`Xeito.Chat.tier/1`)."
  @spec current(keyword()) :: atom()
  def current(chat_opts), do: Xeito.Chat.tier(chat_opts)

  @doc "The configuration of the session's chat tier (`Xeito.Tiers.config/1`), or `[]` when it has none."
  @spec config(keyword()) :: keyword()
  def config(chat_opts), do: Tiers.config(current(chat_opts)) || []

  @doc "The tiers chat can run on."
  @spec tiers() :: [atom()]
  def tiers, do: @chat_tiers

  @doc "Whether chat on `tier` leaves the machine."
  @spec off_box?(atom()) :: boolean()
  def off_box?(tier), do: tier in Tiers.off_box()

  @doc "The tier named by `/model <name>`, if it can chat and is configured (`configs`: tier → config or nil)."
  @spec choose(String.t(), %{atom() => keyword() | nil}) :: {:ok, atom()} | {:error, String.t()}
  def choose(name, configs) do
    name = String.trim(name)

    case Enum.find(@chat_tiers, &(Atom.to_string(&1) == name)) do
      nil -> {:error, "#{name} is not a chat tier (one of: #{Enum.join(@chat_tiers, ", ")})"}
      tier -> configured(tier, configs[tier])
    end
  end

  defp configured(tier, nil) do
    env = "XEITO_" <> String.upcase(Atom.to_string(tier))
    {:error, "#{tier} is not configured: set #{env}_MODEL and #{env}_KEY_FILE for the daemon"}
  end

  defp configured(tier, _cfg), do: {:ok, tier}

  @doc """
  The context window the chat machine fits its requests into on `tier`: the local tier's; for a
  remote one, its configured window, else the model's (`price`, from `Xeito.Allowance`), at most
  128k tokens, which bounds what a call costs.
  """
  @spec context(atom(), keyword(), map() | nil) :: pos_integer() | nil
  def context(:local, cfg, _price), do: cfg[:context]

  def context(_remote, cfg, price),
    do: Keyword.get_lazy(cfg, :context, fn -> min(price[:context] || @remote_context, @remote_context) end)

  @doc "The answer to `/model`: the current tier, then every chat tier."
  @spec describe(atom(), %{atom() => keyword() | nil}, number() | nil) :: String.t()
  def describe(current, configs, left) do
    rows = Enum.map_join(@chat_tiers, "\n", &"  #{String.pad_trailing(Atom.to_string(&1), 17)} #{holds(&1, configs[&1])}")
    "#{line(current, configs[current], left)}\n#{rows}\n/model <tier> switches this session's chat"
  end

  @doc "The notice after a switch to `tier`."
  @spec switched(atom(), keyword(), number()) :: String.t()
  def switched(tier, cfg, max_usd) do
    if off_box?(tier),
      do:
        line(tier, cfg, nil) <>
          "\nThe conversation, and every file the model reads, now leave this machine (OpenRouter, zero data " <>
          "retention). Spend: up to #{usd(max_usd)} per turn (/budget <usd>); /model local switches back.",
      else: line(tier, cfg, nil)
  end

  defp line(tier, cfg, left), do: "chat: #{tier} · #{holds(tier, cfg)}" <> left(left)

  defp holds(_tier, nil), do: "not configured"
  defp holds(tier, cfg), do: "#{cfg[:model]}" <> if(off_box?(tier), do: " · off-box", else: "")

  defp left(nil), do: ""
  defp left(usd), do: " · OpenRouter key: #{usd(usd)} left"

  defp usd(amount), do: "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 2)
end
