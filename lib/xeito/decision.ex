defmodule Xeito.Decision do
  @moduledoc """
  Typed decisions: closed output types with confidence, rationale and provenance.

  A decision type is a module that declares its inputs, its closed set of values (each with a
  description), deterministic rules, the deciders to try, and confidence thresholds:

      defmodule Xeito.Decisions.Triage do
        use Xeito.Decision, version: "1"

        instructions "Why is this test failing?"

        input :test
        input :output, max_bytes: 3_000, keep: :tail

        value :flaky, "timing, randomness, intermittent failure with no code cause"
        value :code_bug, "the code under test computes a wrong result"

        rule :missing_dependency?, then: :env_problem

        deciders [:local_decision, :local]
        min_confidence 0.8

        def missing_dependency?(input), do: input.output =~ "could not be found"
      end

  `Xeito.Decider.decide/3` evaluates a type and returns a `%Xeito.Decision{}`. `:abstain` is an
  implicit value of every type. A type may also be a `Xeito.Decision.Type` built at run time
  (`Xeito.Decisions.AdHoc`), wherever a module is taken.
  """

  alias Xeito.Decision.Type

  @enforce_keys [:type, :value]
  defstruct [
    :type,
    :type_version,
    :value,
    :confidence,
    :actor,
    :model,
    :input_hash,
    :latency_ms,
    cost: %{},
    probabilities: %{},
    evidence: []
  ]

  @type actor ::
          :rule | :local_decision | :remote_decision | :local | :remote | :remote_frontier | :human | :none
  @type t :: %__MODULE__{
          type: module() | Type.t(),
          type_version: String.t() | nil,
          value: atom(),
          confidence: float() | nil,
          actor: actor() | nil,
          model: String.t() | nil,
          input_hash: String.t() | nil,
          latency_ms: non_neg_integer() | nil,
          cost: map(),
          probabilities: %{atom() => float()},
          evidence: [map()]
        }

  defmacro __using__(opts) do
    quote do
      import Xeito.Decision.DSL,
        only: [
          instructions: 1,
          input: 1,
          input: 2,
          value: 2,
          rule: 1,
          rule: 2,
          deciders: 1,
          min_confidence: 1,
          severity: 2,
          policy: 1
        ]

      @xeito_decision_opts unquote(opts)
      @xeito_decision_inputs []
      @xeito_decision_values []
      @xeito_decision_rules []
      @xeito_decision_instructions nil
      @xeito_decision_deciders [:local]
      @xeito_decision_min_confidence 0.8
      @xeito_decision_severity nil
      @xeito_decision_policy []
      @before_compile Xeito.Decision.DSL
    end
  end

  @doc "The compiled type definition of a decision module, or the type itself when built at run time."
  @spec type!(module() | Type.t()) :: Type.t()
  def type!(%Type{} = type), do: type
  def type!(module), do: module.__decision__()

  @doc "A decision type's name for logs and reports: the module, or an ad-hoc type's name."
  @spec describe(module() | Type.t()) :: String.t()
  def describe(%Type{name: name}), do: name
  def describe(module), do: inspect(module)

  @doc "The decision as plain data for logs and reports."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = d), do: Map.from_struct(d)
end
