# Sources held to zero surviving mutants (`mix xeito.mutate`, run by `mix ci`), with the tests
# that cover them; `section:` limits a source to the lines under a `# --- name ---` comment.
# Security and decision logic first: a surviving mutant there is a rule no test pins down.
%{
  "lib/xeito/budget.ex" => ["test/xeito/budget_test.exs"],
  # What the model gets to see: the system prompt must never be cut.
  "lib/xeito/chat/window.ex" => ["test/xeito/chat_window_test.exs"],
  "lib/xeito/decisions/risk.ex" => ["test/xeito/decision_test.exs"],
  "lib/xeito/machines/chat.ex" => [tests: ["test/xeito/chat_machine_test.exs"], section: "guards"],
  "lib/xeito/policy.ex" => ["test/xeito/policy_test.exs"],
  "lib/xeito/undo.ex" => ["test/xeito/undo_test.exs", "test/xeito/undo_env_test.exs"],
  # Slow (every test runs git) and rarely changed: mutated only when they or their tests change.
  "lib/xeito/undo/store.ex" => [
    tests: ["test/xeito/undo_test.exs", "test/xeito/undo_env_test.exs"],
    only_when_changed: true
  ],
  "lib/xeito/undo/branch.ex" => ["test/xeito/undo_test.exs", "test/xeito/undo_env_test.exs"],
  "lib/xeito/undo/outside.ex" => [tests: ["test/xeito/undo_test.exs"], only_when_changed: true],
  "lib/xeito/tui.ex" => [tests: ["test/xeito/tui_test.exs"], section: "the prompt line"]
}
