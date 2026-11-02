defmodule Xeito.Decisions.AdHoc do
  @moduledoc """
  A decision type built for one call, from a question in pi's shapes (`Script.classify/2`):
  `choice` (its options are the values), `bool` (`yes`, `no`) or `score` (the integers of a
  `range`), with `criteria` as the instructions and one input, `state`, the JSON the script
  gives. It is decided on the `local_decision` tier, or `local` without it, like a declared type.

  `type/2` refuses what is not one of the shapes, and bounds what becomes an atom: at most 16
  options, each a short lowercase word, and a range of at most 10 values.
  """

  alias Xeito.Decision.Type

  @max_options 16
  @max_range 10
  @word ~r/^[a-z][a-z0-9_]{0,31}$/

  @doc "The type for question `name`, or why it cannot be one."
  @spec type(String.t(), map()) :: {:ok, Type.t()} | {:error, String.t()}
  def type(name, question) when is_binary(name) and is_map(question) do
    with :ok <- word(name, "a question's name is a short lowercase word"),
         {:ok, values} <- values(name, question),
         {:ok, criteria} <- criteria(name, question) do
      {:ok,
       %Type{
         module: __MODULE__,
         name: "classify:" <> name,
         version: "1",
         instructions: criteria,
         values: values,
         inputs: [%{name: :state, max_bytes: 8_000, keep: :head, required: true}],
         deciders: [:local_decision, :local]
       }}
    end
  end

  def type(_name, _question), do: {:error, "a question is a map with a type and criteria"}

  defp word(text, reason) do
    if is_binary(text) and Regex.match?(@word, text), do: :ok, else: {:error, reason <> ": #{inspect(text)}"}
  end

  defp criteria(_name, %{"criteria" => criteria}) when is_binary(criteria) and criteria != "", do: {:ok, criteria}
  defp criteria(name, _question), do: {:error, "#{name}: criteria are required"}

  defp values(name, %{"type" => "choice"} = question), do: options(name, question["options"])
  defp values(_name, %{"type" => "bool"}), do: {:ok, [{:yes, "yes"}, {:no, "no"}]}
  defp values(name, %{"type" => "score"} = question), do: range(name, question["range"])

  defp values(name, question),
    do: {:error, "#{name}: unknown question type #{inspect(question["type"])}; choice, bool or score"}

  defp options(name, options) when is_list(options) and length(options) >= 2 do
    if length(options) > @max_options,
      do: {:error, "#{name}: at most #{@max_options} options"},
      else: Enum.reduce_while(options, {:ok, []}, &option(name, &1, &2))
  end

  defp options(name, _options), do: {:error, "#{name}: a choice needs at least two options"}

  defp option(name, option, {:ok, acc}) do
    case word(option, "#{name}: an option is a short lowercase word") do
      :ok -> {:cont, {:ok, acc ++ [{String.to_atom(option), option}]}}
      error -> {:halt, error}
    end
  end

  defp range(_name, [min, max]) when is_integer(min) and is_integer(max) and min <= max and max - min < @max_range,
    do: {:ok, for(n <- min..max, do: {String.to_atom(Integer.to_string(n)), Integer.to_string(n)})}

  defp range(name, _range), do: {:error, "#{name}: a score's range is [min, max] with at most #{@max_range} values"}
end
