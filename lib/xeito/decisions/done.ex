defmodule Xeito.Decisions.Done do
  @moduledoc "The decision whether a task is done, can continue or is blocked, taken at the end of work loops."

  use Xeito.Decision, version: "1", name: "done"

  instructions "Given the goal and the latest result, is the task finished?"

  input :goal, max_bytes: 500
  input :last_output, max_bytes: 2_000, keep: :tail
  input :tests, max_bytes: 200, required: false

  value :done, "the goal is achieved and verified; nothing is left to do"
  value :continue, "progress is possible: more steps are needed and nothing prevents them"

  value(
    :blocked,
    "progress needs something the assistant cannot provide: credentials, access, a human decision or an external fix"
  )

  rule :blocked_by_access?, then: :blocked

  # Small tiers failed the zero-shot gate; they decide again once they pass.
  deciders [:local]
  min_confidence 0.8

  @doc false
  def blocked_by_access?(%{last_output: output}) do
    Regex.match?(
      ~r/(Permission denied \(publickey\)|authentication failed|401 Unauthorized|403 Forbidden|rate limit exceeded|could not resolve host)/i,
      output
    )
  end
end
