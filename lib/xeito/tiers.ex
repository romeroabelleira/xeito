defmodule Xeito.Tiers do
  @moduledoc """
  Decider tiers: the places on the escalation ladder (rules, System One, small, large,
  OpenRouter, remote, human).

  A tier's configuration comes from `config :xeito, :tiers` (see `config/runtime.exs`) and names
  the *backend* it speaks (`Xeito.Backends`), a URL, a model and a key; a model tier without a
  `:url` is unavailable. Each tier has a default backend:

  | tier          | default backend |
  |---------------|-----------------|
  | `:rules`      | none: the type's deterministic rules (`Xeito.Tiers.Rules`) |
  | `:system_one` | `:system_one`   |
  | `:small`      | `:llama_server` |
  | `:large`      | `:ollama`       |
  | `:openrouter` | `:openrouter`   |
  | `:remote`     | `:anthropic`    |

  At run time, `Xeito.Machines.Escalation` walks the tiers as a logged state machine under
  `Xeito.Policy`. `Xeito.Decider` is the same ladder in-process, used by evaluation.
  See `docs/architecture/04-delegation.md`.
  """

  alias Xeito.Backends
  alias Xeito.Decision.Type
  alias Xeito.Tiers.Queue

  @type result :: Backends.result()

  @default_backends %{
    system_one: :system_one,
    small: :llama_server,
    large: :ollama,
    openrouter: :openrouter,
    remote: :anthropic
  }

  # Estimated average power while a tier works (joules = watts × seconds). An estimate, not a
  # measurement; deployment-specific values belong in `config :xeito, :tier_watts`. Off-box
  # tiers count 0 here: their energy is spent elsewhere and not measurable from this machine.
  @default_watts %{rules: 0, system_one: 45, small: 65, large: 300, openrouter: 0, remote: 0}

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
