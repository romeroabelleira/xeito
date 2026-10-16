defmodule Xeito.Decision.Scoring do
  @moduledoc """
  Turns token log-probabilities at the value position into a distribution over the options.

  `top_logprobs` come from the unconstrained distribution, so they include tokens the grammar
  forbids. A token counts towards each option it is a prefix of (ignoring leading whitespace);
  a token that could start several options (`test` for `test_bug` and `test_flaky`) is reported
  as ambiguous for the caller to resolve.
  """

  @type tops :: [{String.t(), float()}]
  @type assignment :: %{
          probs: %{String.t() => float()},
          ambiguous: [%{token: String.t(), mass: float(), options: [String.t()]}]
        }

  @doc """
  Assigns probability mass from `tops` (`{token, logprob}`) to `options` (the remaining suffixes
  of the option strings). An empty suffix means the option already ended; it matches a token
  that starts with `"`.
  """
  @spec assign(tops(), [String.t()]) :: assignment()
  def assign(tops, options) do
    Enum.reduce(tops, %{probs: %{}, ambiguous: []}, fn {token, logprob}, acc ->
      mass = :math.exp(logprob)

      case candidates(token, options) do
        [] -> acc
        [one] -> %{acc | probs: Map.update(acc.probs, one, mass, &(&1 + mass))}
        many -> %{acc | ambiguous: [%{token: token, mass: mass, options: many} | acc.ambiguous]}
      end
    end)
  end

  defp candidates(token, options) do
    t = String.trim_leading(token)
    if t == "", do: [], else: Enum.filter(options, &matches?(t, &1))
  end

  defp matches?(token, "" = _ended), do: String.starts_with?(token, "\"")

  defp matches?(token, option), do: String.starts_with?(option, token) or String.starts_with?(token, option <> "\"")

  @doc "Normalises a map of masses to probabilities (empty if there is no mass)."
  @spec normalize(%{any() => float()}) :: %{any() => float()}
  def normalize(masses) do
    total = masses |> Map.values() |> Enum.sum()
    if total > 0, do: Map.new(masses, fn {k, v} -> {k, v / total} end), else: %{}
  end

  @doc """
  Probabilities for `options` from one token position, splitting ambiguous mass evenly between
  its candidates; for backends that cannot continue from a prefix.
  """
  @spec one_step(tops(), [String.t()]) :: %{String.t() => float()}
  def one_step(tops, options) do
    %{probs: probs, ambiguous: ambiguous} = assign(tops, options)

    ambiguous
    |> Enum.reduce(probs, fn %{mass: mass, options: opts}, acc ->
      share = mass / length(opts)
      Enum.reduce(opts, acc, fn o, a -> Map.update(a, o, share, &(&1 + share)) end)
    end)
    |> normalize()
  end

  @doc "The most probable option and its probability, or `nil` for an empty distribution."
  @spec top(%{any() => float()}) :: {any(), float()} | nil
  def top(probs) when map_size(probs) == 0, do: nil
  def top(probs), do: Enum.max_by(probs, fn {_k, p} -> p end)
end
