defmodule Xeito.Decision.DSL do
  @moduledoc "Macros behind `use Xeito.Decision`. Compiles and validates a `Xeito.Decision.Type`."

  alias Xeito.Decision.Type

  @doc "What is being decided, in one or two sentences. Shown to every model tier."
  defmacro instructions(text), do: put(:xeito_decision_instructions, text)

  @doc "Declares an input. Options: `:max_bytes` (default 2 000), `:keep` (`:head` | `:tail`), `:required` (default true)."
  defmacro input(name, opts \\ []) do
    quote do
      @xeito_decision_inputs @xeito_decision_inputs ++
                               [
                                 %{
                                   name: unquote(name),
                                   max_bytes: Keyword.get(unquote(opts), :max_bytes, 2_000),
                                   keep: Keyword.get(unquote(opts), :keep, :head),
                                   required: Keyword.get(unquote(opts), :required, true)
                                 }
                               ]
    end
  end

  @doc "Declares one value of the closed output type, with a description for the models."
  defmacro value(name, description) do
    quote do
      @xeito_decision_values @xeito_decision_values ++ [{unquote(name), unquote(description)}]
    end
  end

  @doc """
  Declares a deterministic rule, tried before any model. `rule :fun, then: value` calls
  `fun(input) :: boolean`; `rule :fun` calls `fun(input) :: value | nil`.
  """
  defmacro rule(fun, opts \\ []) do
    quote do
      @xeito_decision_rules @xeito_decision_rules ++
                              [%{fun: unquote(fun), then: unquote(opts)[:then]}]
    end
  end

  @doc "The model tiers to try, in order, when no rule fires."
  defmacro deciders(list), do: put(:xeito_decision_deciders, list)

  @doc "Confidence threshold: a number, or a map per tier."
  defmacro min_confidence(threshold), do: put(:xeito_decision_min_confidence, threshold)

  @doc """
  Makes the type monotonic: values are ordered by severity, and when no rule fires the result
  is at least `floor:`. A model can then only *raise* the outcome, never lower it.
  """
  defmacro severity(order, opts),
    do:
      put(
        :xeito_decision_severity,
        quote(do: %{order: unquote(order), floor: unquote(opts)[:floor]})
      )

  defp put(attr, value) do
    quote do: Module.put_attribute(__MODULE__, unquote(attr), unquote(value))
  end

  defmacro __before_compile__(env) do
    module = env.module
    get = &Module.get_attribute(module, &1)
    opts = get.(:xeito_decision_opts)

    type = %Type{
      module: module,
      name:
        Keyword.get_lazy(opts, :name, fn ->
          module |> Module.split() |> List.last() |> Macro.underscore()
        end),
      version: Keyword.fetch!(opts, :version),
      instructions: get.(:xeito_decision_instructions),
      inputs: get.(:xeito_decision_inputs),
      values: get.(:xeito_decision_values),
      rules: get.(:xeito_decision_rules),
      deciders: get.(:xeito_decision_deciders),
      min_confidence: get.(:xeito_decision_min_confidence),
      severity: get.(:xeito_decision_severity)
    }

    case validate(type, &Module.defines?(module, &1, :def)) do
      [] ->
        quote do
          @doc false
          def __decision__, do: unquote(Macro.escape(type))
        end

      errors ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "invalid decision #{inspect(module)}:\n  * " <> Enum.join(errors, "\n  * ")
    end
  end

  defp validate(type, defines?) do
    values = Type.values(type)

    Enum.concat([
      if(is_binary(type.instructions), do: [], else: ["`instructions` is required"]),
      if(length(values) >= 2, do: [], else: ["at least two values are required"]),
      if(:abstain in values, do: ["`:abstain` is implicit and cannot be declared"], else: []),
      if(length(Enum.uniq(values)) == length(values), do: [], else: ["values must be unique"]),
      if(type.inputs != [], do: [], else: ["at least one input is required"]),
      for(
        %{fun: fun} <- type.rules,
        not defines?.({fun, 1}),
        do: "rule #{fun}/1 must be a public function"
      ),
      for(
        %{then: v} <- type.rules,
        v != nil,
        v not in values,
        do: "rule result #{inspect(v)} is not a value"
      ),
      severity_errors(type.severity, values)
    ])
  end

  defp severity_errors(nil, _values), do: []

  defp severity_errors(%{order: order, floor: floor}, values) do
    if Enum.sort(order) == Enum.sort(values) and floor in values,
      do: [],
      else: ["severity order must list every value exactly once and floor must be a value"]
  end
end
