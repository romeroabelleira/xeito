defmodule Xeito.Tiers do
  @moduledoc """
  Decider tiers: the places on the escalation ladder, named by the kind of model and where it
  runs. Besides them, the ladder starts with the type's rules and may end with a human.

  | tier               | kind                                                   | default backend |
  |--------------------|--------------------------------------------------------|-----------------|
  | `:local_decision`  | System One decision model on this machine (Laya)       | `:system_one`   |
  | `:remote_decision` | System One decision model, hosted (Jev)                | `:system_one`   |
  | `:local`           | language model on the local GPU: chat and decisions    | `:ollama`       |
  | `:remote`          | hosted language model with logprobs (calibrated)       | `:openrouter`   |
  | `:remote_frontier` | the strongest hosted language model; answers terminally | `:openrouter`  |

  A tier's configuration comes from `config :xeito, :tiers` (read from the environment by
  `Xeito.Tiers.Settings`) and names the backend it speaks (`Xeito.Backends`), a URL, a model and
  a key; a tier without a `:url` is unavailable. Every `remote*` tier is off-box: `Xeito.Policy`
  gates them together.

  At run time, `Xeito.Machines.Escalation` walks the tiers as a logged state machine under
  `Xeito.Policy`. `Xeito.Decider` is the same ladder in-process, used by evaluation.
  See `docs/architecture/04-delegation.md`.
  """

  alias Xeito.Backends
  alias Xeito.Decision.Type
  alias Xeito.Tiers.Queue

  @type result :: Backends.result()

  @all [:local_decision, :remote_decision, :local, :remote, :remote_frontier]
  @off_box [:remote_decision, :remote, :remote_frontier]

  @default_backends %{
    local_decision: :system_one,
    remote_decision: :system_one,
    local: :ollama,
    remote: :openrouter,
    remote_frontier: :openrouter
  }

  # Estimated average power while a tier works (joules = watts × seconds). An estimate, not a
  # measurement; deployment-specific values belong in `config :xeito, :tier_watts`. Off-box
  # tiers count 0 here: their energy is spent elsewhere and not measurable from this machine.
  @default_watts %{rules: 0, local_decision: 45, local: 300, remote_decision: 0, remote: 0, remote_frontier: 0}

  @doc "The model tiers, in ladder order."
  @spec all() :: [atom()]
  def all, do: @all

  @doc "The tiers that send their input off the machine: every remote one."
  @spec off_box() :: [atom()]
  def off_box, do: @off_box

  # Settings that follow from a tier's kind: the frontier tier answers terminally, so it asks
  # for no logprobs (which models such as Claude cannot return).
  @kind_defaults %{remote_frontier: [logprobs: false]}

  @doc "The configuration of a tier, merged with overrides; `nil` if a model tier has no URL."
  @spec config(atom(), keyword()) :: keyword() | nil
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

  @doc """
  Runs one tier for a decision: resolves its configuration, waits for a capacity slot
  (`Xeito.Tiers.Queue`), calls the backend, and completes the cost with an energy estimate.
  """
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
