defmodule Xeito.Policy do
  @moduledoc """
  Escalation policy: which tiers a decision may use, under which limits. Policy is data and code,
  never a prompt (`docs/architecture/04-delegation.md#guards-on-escalation`).

  Sources, merged in order (later wins):
    1. defaults below
    2. `config :xeito, :policy` (deployment-wide)
    3. the decision type's `policy` declaration (e.g. `Risk` forbids the remote tier)
    4. per-request options (`Xeito.Decider` / effect options)

  Off-box tiers (`off_box_tiers/0`: `:openrouter`, `:remote`) send the input to a third party.
  They share one gate, the `:remote` key, one locality rule and one spend budget.

  Keys:
    * `:remote` — `:forbidden` (default) or `:allowed`, for every off-box tier
    * `:locality` — `:local_only` (default) or `:public`. `:local_only` inputs never leave the
      machine, whatever `:remote` says
    * `:max_usd_per_run` — off-box spend limit per parent run (default 0.50)
    * `:max_swaps_per_run` — large-model loads per parent run (default 3)
    * `:unloaded_accept` — when the large model is not loaded, accept an earlier small-tier
      answer whose confidence is at least this, instead of swapping (default 0.6; `nil` disables)
    * `:human` — whether to end the ladder with a human prompt (default false; most machines
      handle `:abstain` themselves)
    * `:human_timeout` — how long a human prompt waits (default 10 minutes)
  """

  alias Xeito.{Budget, Tiers}
  alias Xeito.Decision.Type

  @off_box [:openrouter, :remote]

  @defaults %{
    remote: :forbidden,
    locality: :local_only,
    max_usd_per_run: 0.50,
    max_swaps_per_run: 3,
    unloaded_accept: 0.6,
    human: false,
    human_timeout: 600_000
  }

  @doc "The effective policy for a decision type and request options."
  @spec for_type(Type.t(), keyword()) :: map()
  def for_type(%Type{} = type, opts \\ []) do
    @defaults
    |> Map.merge(Map.new(Application.get_env(:xeito, :policy, [])))
    |> Map.merge(Map.new(type.policy || []))
    |> Map.merge(Map.new(Keyword.get(opts, :policy, [])))
    |> enforce_type(type)
  end

  # A type-level :forbidden cannot be relaxed by configuration or request options.
  defp enforce_type(policy, type) do
    if Keyword.get(type.policy || [], :remote) == :forbidden,
      do: %{policy | remote: :forbidden},
      else: policy
  end

  @doc """
  The ordered tiers a decision will try: rules first, then the requested model tiers that are
  configured and permitted, then the human if the policy asks for one.
  """
  @spec plan(map(), [atom()], String.t() | nil, (atom() -> boolean())) :: [atom()]
  def plan(policy, tiers, parent_run \\ nil, available? \\ &(Tiers.config(&1) != nil)) do
    models =
      tiers
      |> Enum.uniq()
      |> Enum.filter(
        &((&1 not in @off_box or remote_allowed?(policy, parent_run)) and available?.(&1))
      )

    [:rules] ++ models ++ if(policy.human, do: [:human], else: [])
  end

  @doc "The tiers that send inputs off the machine."
  @spec off_box_tiers() :: [atom()]
  def off_box_tiers, do: @off_box

  @doc "Whether an off-box tier may be called now for this policy and run."
  @spec remote_allowed?(map(), String.t() | nil) :: boolean()
  def remote_allowed?(policy, parent_run) do
    policy.remote == :allowed and policy.locality == :public and
      (parent_run == nil or Budget.get(parent_run, :usd) < policy.max_usd_per_run)
  end

  @doc "Whether another large-model swap is allowed for this run."
  @spec swap_allowed?(map(), String.t() | nil) :: boolean()
  def swap_allowed?(policy, parent_run),
    do: parent_run == nil or Budget.get(parent_run, :swaps) < policy.max_swaps_per_run
end
