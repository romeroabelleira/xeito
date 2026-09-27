defmodule Xeito.Decisions.Triage do
  @moduledoc "Why is a test failing? Used by `Xeito.Machines.FixFailingTest`."

  use Xeito.Decision, version: "1"

  instructions("Why is this test failing?")

  input(:test, max_bytes: 300)
  input(:output, max_bytes: 3_000, keep: :tail)
  input(:diff_stat, max_bytes: 500, required: false)

  value(:flaky, "timing, randomness or ordering: an intermittent failure with no code cause")
  value(:code_bug, "the code under test computes a wrong result or crashes")
  value(:test_bug, "the test's own expectation, setup or fixture is wrong")

  value(
    :env_problem,
    "missing dependency, service, file, permission or configuration in the environment"
  )

  rule(:missing_environment?, then: :env_problem)
  rule(:timeout_only?, then: :flaky)

  # Small tiers failed the zero-shot gate in P2 (bench/2-decisions.md); they decide again once they pass.
  deciders([:large])
  min_confidence(0.8)

  defp env_pattern,
    do:
      ~r/(could not be found|ModuleNotFoundError|No module named|command not found|ECONNREFUSED|[Cc]onnection refused|Permission denied|getaddrinfo|could not resolve host|is not available.*\(Mix\)|database .* does not exist|role .* does not exist)/

  @doc false
  def missing_environment?(%{output: output}), do: Regex.match?(env_pattern(), output)

  @doc false
  def timeout_only?(%{output: output}) do
    Regex.match?(~r/(timed? ?out|exceeded timeout|deadline exceeded)/i, output) and
      not Regex.match?(~r/(assert|expected|Expected|left:|right:)/, output)
  end
end
