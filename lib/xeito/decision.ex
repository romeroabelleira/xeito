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

        deciders [:system_one, :small]
        min_confidence 0.8

        def missing_dependency?(input), do: input.output =~ "could not be found"
      end

  `Xeito.Decider.decide/3` evaluates a type. The result is a `%Xeito.Decision{}` record.
  `:abstain` is an implicit value of every type.

  See `docs/architecture/03-typed-decisions.md`.
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
    probabilities: %{},
    evidence: []
  ]

  @type actor :: :rule | :system_one | :small | :large | :remote | :human | :none
  @type t :: %__MODULE__{
          type: module(),
          type_version: String.t() | nil,
          value: atom(),
          confidence: float() | nil,
          actor: actor() | nil,
          model: String.t() | nil,
          input_hash: String.t() | nil,
          latency_ms: non_neg_integer() | nil,
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
          severity: 2
        ]

      @xeito_decision_opts unquote(opts)
      @xeito_decision_inputs []
      @xeito_decision_values []
      @xeito_decision_rules []
      @xeito_decision_instructions nil
      @xeito_decision_deciders [:system_one, :small]
      @xeito_decision_min_confidence 0.8
      @xeito_decision_severity nil
      @before_compile Xeito.Decision.DSL
    end
  end

  @doc "The compiled type definition of a decision module."
  @spec type!(module()) :: Type.t()
  def type!(module), do: module.__decision__()

  @doc "The decision as plain data for logs and reports."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = d), do: Map.from_struct(d)
end
