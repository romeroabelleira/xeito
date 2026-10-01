# Sources held to zero surviving mutants (`mix xeito.mutate`, run by `mix ci`), with the tests
# that cover them; `section:` limits a source to the lines under a `# --- name ---` comment.
# Security and decision logic first: a surviving mutant there is a rule no test pins down.
%{
  "lib/xeito/budget.ex" => ["test/xeito/budget_test.exs"],
  "lib/xeito/decisions/risk.ex" => ["test/xeito/decision_test.exs"],
  "lib/xeito/machines/chat.ex" => [tests: ["test/xeito/chat_machine_test.exs"], section: "guards"],
  "lib/xeito/policy.ex" => ["test/xeito/policy_test.exs"],
  "lib/xeito/tui.ex" => [tests: ["test/xeito/tui_test.exs"], section: "the prompt line"]
}
