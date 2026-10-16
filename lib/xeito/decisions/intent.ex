defmodule Xeito.Decisions.Intent do
  @moduledoc "Decision that classifies a free-form request by what the user wants, to select a machine."

  use Xeito.Decision, version: "2"

  instructions "What does the user want the coding assistant to do with this message?"

  input :message, max_bytes: 2_000

  value(
    :question,
    "a factual question about the code, project or tools, or about what the assistant did in this session, answerable by looking things up"
  )

  value :edit, "change, add, fix, refactor or delete code or files"
  value :run, "execute a command, script, test suite, build or deployment"
  value :explain, "explain how or why code, an error or a concept works"
  value :plan, "design an approach, break down work or propose steps before changing anything"
  value :other, "greeting, thanks, chit-chat or anything unrelated to the project"

  rule :slash_run?, then: :run
  rule :small_talk?, then: :other
  rule :run_tests?, then: :run

  # Smaller tiers are left out until they pass the zero-shot gate.
  deciders [:local]
  min_confidence 0.75

  @doc false
  def small_talk?(%{message: message}) do
    Regex.match?(
      ~r/\A\s*(hi|hello|hey|hallo|hola|thanks?|thank you|thx|ok(ay)?|cheers|good (morning|afternoon|evening)|bye)[\s!.,:)]*\z/i,
      message
    )
  end

  @doc false
  def run_tests?(%{message: message}),
    do: Regex.match?(~r/\A\s*(please\s+)?run\s+(the\s+|all\s+)?(tests?|test suite|specs?)[\s.!]*\z/i, message)

  @doc false
  def slash_run?(%{message: message}), do: String.starts_with?(String.trim_leading(message), "/run ")
end
