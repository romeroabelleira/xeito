defmodule Xeito.Machine do
  @moduledoc """
  Versioned statechart definitions: states, events, guards, timeouts and final states.

  A machine is written with a small DSL and compiled into plain data (`%Xeito.Machine{}`),
  which the generic run process interprets, the exporters turn into Mermaid or SCXML,
  and later phases turn into Petri nets for conformance checking.

      defmodule MyMachine do
        use Xeito.Machine, name: "run_tests", version: "0.1.0"

        initial :running

        state :running, entry: :run_tests, timeout: 600_000 do
          on :ran, to: :done, guard: :passed?
          on :ran, to: :failed
        end

        final :done
        final :failed

        def run_tests(ctx), do: [Xeito.Effect.bash("mix test", cwd: ctx.cwd)]
        def passed?(_ctx, result), do: result.exit_status == 0
      end

  Guards, entry functions and actions are *names of public functions* in the machine
  module, so a machine definition stays serialisable data:

    * `entry: :fun` — `fun(ctx) :: [Xeito.Effect.t()]`, effects to run when the state is entered
    * `guard: :fun` — `fun(ctx, event_data) :: boolean()`, must be pure
    * `action: :fun` — `fun(ctx, event_data) :: ctx`, pure context update on the transition

  Every non-final state has a timeout: either `timeout: ms | {ms, event}` or the machine's
  `default_timeout` (5 minutes). A timeout that no transition handles moves the run to the
  mandatory `:failed` final state. Validation happens at compile time; see
  `Xeito.Machine.Validator`.

  See `docs/architecture/02-state-machine-core.md`.
  """

  alias Xeito.Machine.State

  @enforce_keys [:module, :name, :version, :initial]
  defstruct [:module, :name, :version, :initial, states: %{}, order: [], default_timeout: 300_000]

  @type state_name :: atom()
  @type event_name :: term()
  @type t :: %__MODULE__{
          module: module(),
          name: String.t(),
          version: String.t(),
          initial: state_name(),
          states: %{state_name() => State.t()},
          order: [state_name()],
          default_timeout: pos_integer()
        }

  defmacro __using__(opts) do
    quote do
      import Xeito.Machine.DSL, only: [initial: 1, state: 2, state: 3, final: 1, on: 2, decide: 1]

      @xeito_opts unquote(opts)
      @xeito_stack []
      @xeito_states %{}
      @xeito_order []
      @xeito_initial nil
      @before_compile Xeito.Machine.DSL
    end
  end

  @doc "Returns the compiled machine definition of a machine module."
  @spec fetch!(module()) :: t()
  def fetch!(module), do: module.__machine__()

  @doc "Returns the state definition for `name`."
  @spec state!(t(), state_name()) :: State.t()
  def state!(%__MODULE__{states: states}, name), do: Map.fetch!(states, name)

  @doc "Direct children of a state, in definition order."
  @spec children(t(), state_name()) :: [state_name()]
  def children(%__MODULE__{} = machine, name) do
    Enum.filter(machine.order, &(machine.states[&1].parent == name))
  end

  @doc "Top-level states, in definition order."
  @spec roots(t()) :: [state_name()]
  def roots(%__MODULE__{} = machine), do: children(machine, nil)

  @doc "Whether a state has child states."
  @spec compound?(t(), state_name()) :: boolean()
  def compound?(machine, name), do: children(machine, name) != []

  @doc "The state itself followed by its ancestors, innermost first."
  @spec lineage(t(), state_name()) :: [state_name()]
  def lineage(%__MODULE__{} = machine, name) do
    case machine.states[name].parent do
      nil -> [name]
      parent -> [name | lineage(machine, parent)]
    end
  end

  @doc "Resolves a state to the leaf that becomes active, following `initial:` children."
  @spec leaf(t(), state_name()) :: state_name()
  def leaf(%__MODULE__{} = machine, name) do
    case machine.states[name].initial do
      nil -> name
      child -> leaf(machine, child)
    end
  end

  @doc "Whether a state is final."
  @spec final?(t(), state_name()) :: boolean()
  def final?(machine, name), do: state!(machine, name).final

  @doc "The `{milliseconds, event}` timeout that applies while `name` is the active leaf."
  @spec timeout(t(), state_name()) :: {pos_integer(), event_name()} | nil
  def timeout(machine, name) do
    state = state!(machine, name)

    cond do
      state.final -> nil
      state.timeout -> state.timeout
      true -> {machine.default_timeout, :timeout}
    end
  end
end
