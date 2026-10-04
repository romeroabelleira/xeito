defmodule Xeito.Decisions do
  @moduledoc "Registry of the built-in decision types."

  @all [
    Xeito.Decisions.Intent,
    Xeito.Decisions.Triage,
    Xeito.Decisions.Risk,
    Xeito.Decisions.Done,
    Xeito.Decisions.Skill
  ]

  @doc "All built-in decision type modules."
  @spec all() :: [module()]
  def all, do: @all

  @doc "Finds a decision type module by its name (`\"triage\"`)."
  @spec fetch!(String.t()) :: module()
  def fetch!(name) do
    Enum.find(@all, &(&1.__decision__().name == name)) ||
      raise ArgumentError, "unknown decision type #{inspect(name)}"
  end
end
