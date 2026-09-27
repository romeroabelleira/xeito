defmodule Xeito.Machine.DSL do
  @moduledoc """
  Macros behind `use Xeito.Machine`. They accumulate states in module attributes while the
  module body is evaluated, then compile and validate the `%Xeito.Machine{}` in
  `__before_compile__/1`.
  """

  alias Xeito.Machine
  alias Xeito.Machine.{State, Transition, Validator}

  @doc "Sets the machine's initial state."
  defmacro initial(name) do
    quote do: Module.put_attribute(__MODULE__, :xeito_initial, unquote(name))
  end

  @doc """
  Declares a state. Options: `:initial` (child to enter, for compound states), `:entry`,
  `:timeout` (`ms` or `{ms, event}`). Nested `state` blocks declare child states.
  """
  defmacro state(name, opts) do
    {block, opts} = Keyword.pop(opts, :do)
    build_state(name, opts, block)
  end

  @doc false
  defmacro state(name, opts, do: block), do: build_state(name, opts, block)

  @doc "Declares a final state."
  defmacro final(name) do
    quote do
      unquote(__MODULE__).__open_state__(__MODULE__, unquote(name), final: true)
      unquote(__MODULE__).__close_state__(__MODULE__)
    end
  end

  @doc "Declares a transition on `event`. Options: `:to` (required), `:guard`, `:action`."
  defmacro on(event, opts) do
    quote do: unquote(__MODULE__).__add_transition__(__MODULE__, unquote(event), unquote(opts))
  end

  @doc """
  Declares that the state requests the typed decision `name` on entry. The decision's result
  arrives as the event `{:decided, value}`.
  """
  defmacro decide(name) do
    quote do: unquote(__MODULE__).__set_decision__(__MODULE__, unquote(name))
  end

  defp build_state(name, opts, block) do
    quote do
      unquote(__MODULE__).__open_state__(__MODULE__, unquote(name), unquote(opts))
      unquote(block)
      unquote(__MODULE__).__close_state__(__MODULE__)
    end
  end

  @doc false
  def __open_state__(module, name, opts) do
    states = Module.get_attribute(module, :xeito_states)
    stack = Module.get_attribute(module, :xeito_stack)

    if Map.has_key?(states, name),
      do: raise(ArgumentError, "state #{inspect(name)} is declared twice")

    state = %State{
      name: name,
      parent: List.first(stack),
      initial: opts[:initial],
      entry: opts[:entry],
      timeout: normalize_timeout(opts[:timeout]),
      final: Keyword.get(opts, :final, false)
    }

    Module.put_attribute(module, :xeito_states, Map.put(states, name, state))

    Module.put_attribute(
      module,
      :xeito_order,
      Module.get_attribute(module, :xeito_order) ++ [name]
    )

    Module.put_attribute(module, :xeito_stack, [name | stack])
  end

  @doc false
  def __close_state__(module) do
    [_ | rest] = Module.get_attribute(module, :xeito_stack)
    Module.put_attribute(module, :xeito_stack, rest)
  end

  @doc false
  def __add_transition__(module, event, opts) do
    transition = %Transition{
      event: event,
      to: Keyword.fetch!(opts, :to),
      guard: opts[:guard],
      action: opts[:action]
    }

    update_current(module, "on", fn state ->
      %{state | transitions: state.transitions ++ [transition]}
    end)
  end

  @doc false
  def __set_decision__(module, name) do
    update_current(module, "decide", &%{&1 | decision: name})
  end

  defp update_current(module, macro, fun) do
    case Module.get_attribute(module, :xeito_stack) do
      [current | _] ->
        states = Module.get_attribute(module, :xeito_states)
        Module.put_attribute(module, :xeito_states, Map.update!(states, current, fun))

      [] ->
        raise ArgumentError, "`#{macro}` must be used inside a `state` block"
    end
  end

  defp normalize_timeout(nil), do: nil
  defp normalize_timeout(ms) when is_integer(ms) and ms > 0, do: {ms, :timeout}
  defp normalize_timeout({ms, event}) when is_integer(ms) and ms > 0, do: {ms, event}

  defp normalize_timeout(other),
    do: raise(ArgumentError, "invalid timeout #{inspect(other)}, expected ms or {ms, event}")

  defmacro __before_compile__(env) do
    module = env.module
    opts = Module.get_attribute(module, :xeito_opts)

    machine = %Machine{
      module: module,
      name: Keyword.get_lazy(opts, :name, fn -> default_name(module) end),
      version: Keyword.fetch!(opts, :version),
      default_timeout: Keyword.get(opts, :default_timeout, 300_000),
      initial: Module.get_attribute(module, :xeito_initial),
      states: Module.get_attribute(module, :xeito_states),
      order: Module.get_attribute(module, :xeito_order)
    }

    case Validator.validate(machine, &Module.defines?(module, &1, :def)) do
      :ok ->
        quote do
          @doc false
          def __machine__, do: unquote(Macro.escape(machine))
        end

      {:error, errors} ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "invalid machine #{inspect(module)}:\n  * " <> Enum.join(errors, "\n  * ")
    end
  end

  defp default_name(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end
end
