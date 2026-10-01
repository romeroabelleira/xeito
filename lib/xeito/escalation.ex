defmodule Xeito.Escalation do
  @moduledoc """
  Runs a typed decision as an escalation machine (`Xeito.Machines.Escalation`): a child run of
  the requesting run, logged in the same OCEL log and related to its parent (`part_of`).

  `decide/3` builds the plan from `Xeito.Policy`, starts the child run (or finds it, if the same
  request is being retried after a crash: the child id is derived from the requesting effect),
  waits for it to finish, and returns the `%Xeito.Decision{}` it committed.
  """

  alias Xeito.Decision
  alias Xeito.Decision.Type
  alias Xeito.Log
  alias Xeito.Machines
  alias Xeito.Policy
  alias Xeito.Run
  alias Xeito.RunSupervisor

  @doc """
  Decides `type_module` for `input`. Options:

    * `:log` — the log to write to (required)
    * `:parent` — the requesting run's id (budgets and the `part_of` relation)
    * `:id` — the escalation run id (default derived from `:effect_id`, or random)
    * `:deciders` — the model tiers to consider (default: the type's `deciders`)
    * `:policy` — policy overrides (`Xeito.Policy`)
    * `:tiers` — tier configuration overrides, passed to the runner
    * `:available?` — tier availability function (tests)
    * `:timeout` — how long to wait for the run (default 15 minutes)
  """
  @spec decide(module(), map(), keyword()) :: Decision.t()
  def decide(type_module, input, opts) do
    started = System.monotonic_time(:millisecond)
    log = Keyword.fetch!(opts, :log)
    type = Decision.type!(type_module)
    normalized = Type.normalize_input(type, input)
    parent = opts[:parent]
    policy = Policy.for_type(type, opts)

    available? = Keyword.get(opts, :available?, &available?(&1, opts))

    [:rules | plan] =
      Policy.plan(policy, Keyword.get(opts, :deciders, type.deciders), parent, available?)

    ctx = %{
      type: type_module,
      input: normalized,
      plan: plan,
      policy: policy,
      parent: parent,
      attempts: [],
      decision: nil,
      base: %Decision{
        type: type_module,
        type_version: type.version,
        value: :abstain,
        input_hash: Type.input_hash(type, normalized)
      }
    }

    id = Keyword.get_lazy(opts, :id, fn -> child_id(opts[:effect_id]) end)

    runner =
      {Xeito.Effects.Local, [log: log, run_id: id, parent_run: parent, tiers: Keyword.get(opts, :tiers, [])]}

    {:ok, ^id} = start(Machines.Escalation, ctx, id, log, runner)
    if parent, do: Log.relate(log, id, parent, "part_of")

    decision =
      case await(log, id, Keyword.get(opts, :timeout, 900_000)) do
        {:ok, %{ctx: %{decision: %Decision{} = d}}} -> d
        {:ok, %{state: state}} -> %{ctx.base | actor: :none, evidence: [%{escalation: state}]}
        :timeout -> %{ctx.base | actor: :none, evidence: [%{escalation: :timeout, run: id}]}
      end

    # Wall-clock time of the whole escalation, including queueing and swaps.
    %{decision | latency_ms: System.monotonic_time(:millisecond) - started}
  end

  defp available?(tier, opts) do
    Keyword.has_key?(Keyword.get(opts, :tiers, []), tier) or Xeito.Tiers.config(tier) != nil
  end

  defp child_id(nil), do: "esc-" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)

  defp child_id(effect_id), do: effect_id <> "/esc"

  defp start(machine, ctx, id, log, runner) do
    case RunSupervisor.start_run(machine, ctx, run_id: id, log: log, runner: runner) do
      {:ok, id} -> {:ok, id}
      {:error, {:already_started, _pid}} -> {:ok, id}
    end
  end

  @doc "Waits until run `id` has finished (see `Xeito.Run.await/3`)."
  @spec await(Log.server(), String.t(), timeout()) :: {:ok, map()} | :timeout
  defdelegate await(log, id, timeout), to: Run
end
