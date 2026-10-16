defmodule Xeito.Tiers do
  @moduledoc """
  The model tiers of the escalation ladder, their configuration, and one tier call with a cost.

  The ladder starts with the type's rules (`:rules`) and may end with a human.

  | tier               | kind                                                   | default backend |
  |--------------------|--------------------------------------------------------|-----------------|
  | `:local_decision`  | System One decision model on this machine              | `:system_one`   |
  | `:remote_decision` | System One decision model, hosted                      | `:system_one`   |
  | `:local`           | language model on the local GPU: chat and decisions    | `:ollama`       |
  | `:remote`          | hosted language model with logprobs (calibrated)       | `:openrouter`   |
  | `:remote_frontier` | the strongest hosted language model; answers terminally | `:openrouter`  |

  A tier's configuration comes from `config :xeito, :tiers`: `:backend` (`Xeito.Backends`),
  `:url`, `:model` and an API key. A tier without a `:url` is unavailable. Every `remote*` tier is off-box
  and gated by `Xeito.Policy`.
  """

  alias Xeito.Backends
  alias Xeito.Decision.Type
  alias Xeito.Tiers.Queue

  @type result :: Backends.result()

  @typedoc """
  A tier's configuration, from `Xeito.Tiers.Settings` merged with per-call overrides. Backends
  read the keys that apply to them; chat adds `run` and `max_usd` (the run whose off-box budget
  it draws on, and that budget).
  """
  @type config :: [
          {:backend, atom()}
          | {:url, String.t()}
          | {:model, String.t()}
          | {:api_key, String.t()}
          | {:context, pos_integer()}
          | {:keep_alive, String.t()}
          | {:providers, [String.t()]}
          | {:zdr, boolean()}
          | {:reasoning, String.t()}
          | {:logprobs, boolean()}
          | {:top_logprobs, pos_integer()}
          | {:max_tokens, pos_integer()}
          | {:temperature, number()}
          | {:timeout, pos_integer()}
          | {:think, boolean()}
          | {:chat_model, String.t()}
          | {:run, String.t() | nil}
          | {:max_usd, number()}
          | {:plug, term()}
        ]

  @all [:local_decision, :remote_decision, :local, :remote, :remote_frontier]
  @off_box [:remote_decision, :remote, :remote_frontier]

  @default_backends %{
    local_decision: :system_one,
    remote_decision: :system_one,
    local: :ollama,
    remote: :openrouter,
    remote_frontier: :openrouter
  }

  # Estimated watts while a tier works; overridden by `config :xeito, :tier_watts`. Off-box: 0.
  @default_watts %{rules: 0, local_decision: 45, local: 300, remote_decision: 0, remote: 0, remote_frontier: 0}

  @doc "The model tiers, in ladder order."
  @spec all() :: [atom()]
  def all, do: @all

  @doc "The tiers that send their input off the machine: every remote one."
  @spec off_box() :: [atom()]
  def off_box, do: @off_box

  # The frontier tier answers terminally, so it asks for no logprobs.
  @kind_defaults %{remote_frontier: [logprobs: false]}

  @doc "The configuration of a tier, merged with overrides; `nil` if a model tier has no URL."
  @spec config(atom(), keyword()) :: config() | nil
  def config(tier, overrides \\ [])
  def config(:rules, overrides), do: overrides

  def config(tier, overrides) do
    cfg =
      :xeito
      |> Application.get_env(:tiers, [])
      |> Keyword.get(tier, [])
      |> Keyword.merge(overrides)
      |> then(&Keyword.merge(Map.get(@kind_defaults, tier, []), &1))

    if cfg[:url], do: cfg
  end

  @doc "The backend a tier speaks: its configuration's `:backend`, else the tier's default."
  @spec backend(atom(), keyword()) :: atom()
  def backend(tier, cfg), do: Keyword.get_lazy(cfg, :backend, fn -> Map.fetch!(@default_backends, tier) end)

  @doc "Runs one tier for a decision in its capacity queue; the result's cost includes `joules_est`."
  @spec run(atom(), Type.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(tier, type, input, overrides \\ []) do
    case config(tier, overrides) do
      nil ->
        {:error, :tier_unavailable}

      cfg ->
        tier
        |> Queue.run(fn -> decide(tier, cfg, type, input) end)
        |> add_energy(tier)
    end
  end

  defp decide(:rules, cfg, type, input), do: Xeito.Tiers.Rules.decide(type, input, cfg)

  defp decide(tier, cfg, type, input) do
    backend = backend(tier, cfg)

    case Backends.module(backend) do
      {:ok, module} -> module.decide(type, input, cfg)
      :error -> {:error, {:unknown_backend, backend}}
    end
  end

  defp add_energy({:ok, result}, tier) do
    watts =
      :xeito
      |> Application.get_env(:tier_watts, %{})
      |> Map.get(tier, Map.fetch!(@default_watts, tier))

    joules = Float.round(watts * result.latency_ms / 1000, 3)
    {:ok, Map.update(result, :cost, %{joules_est: joules}, &Map.put(&1, :joules_est, joules))}
  end

  defp add_energy(error, _tier), do: error
end
