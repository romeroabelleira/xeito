# Sources held to zero surviving mutants (`mix xeito.mutate`, run by `mix ci`), with the tests
# that cover them; `section:` limits a source to the lines under a `# --- name ---` comment.
# Security and decision logic first: a surviving mutant there is a rule no test pins down.
%{
  # Whether a remote chat call may spend money. Only the pure part: a mutant of the cache's server
  # crashes the supervised process until the application stops, which fails the next source's tests.
  "lib/xeito/allowance.ex" => [
    tests: ["test/xeito/allowance_test.exs", "test/xeito/chat_test.exs"],
    section: "pure"
  ],
  "lib/xeito/budget.ex" => ["test/xeito/budget_test.exs"],
  # What the model gets to see: the system prompt must never be cut.
  "lib/xeito/chat/window.ex" => ["test/xeito/chat/window_test.exs"],
  "lib/xeito/decisions/risk.ex" => ["test/xeito/decision_test.exs"],
  # Which commands and flags read, write or run: a wrong case lets a write or a program through.
  "lib/xeito/decisions/risk/commands.ex" => [
    "test/xeito/decisions/risk/commands_test.exs",
    "test/xeito/decision_test.exs"
  ],
  # When a chat turn runs a call, stops, or checks and fixes its edits: the machine's guards and
  # the logic behind them.
  "lib/xeito/machines/chat.ex" => [
    tests: ["test/xeito/machines/chat_test.exs", "test/xeito/skills_per_turn_test.exs"],
    section: "guards"
  ],
  "lib/xeito/machines/chat/calls.ex" => [
    "test/xeito/machines/chat/calls_test.exs",
    "test/xeito/machines/chat_test.exs"
  ],
  "lib/xeito/machines/chat/checks.ex" => [
    "test/xeito/machines/chat/checks_test.exs",
    "test/xeito/machines/chat_test.exs"
  ],
  "lib/xeito/machines/chat/limits.ex" => [
    "test/xeito/machines/chat/limits_test.exs",
    "test/xeito/machines/chat_test.exs"
  ],
  "lib/xeito/policy.ex" => ["test/xeito/policy_test.exs"],
  # Which commands run without asking the human again.
  "lib/xeito/session/allowed.ex" => ["test/xeito/session/allowed_test.exs"],
  # Which skills a turn may choose from, and so whether it needs a model call to decide.
  "lib/xeito/skills/index.ex" => [
    tests: [
      "test/xeito/skills/index_test.exs",
      "test/xeito/skill_keywords_test.exs",
      "test/xeito/skills/examples_test.exs"
    ],
    section: "matching"
  ],
  "lib/xeito/undo.ex" => ["test/xeito/undo_test.exs", "test/xeito/undo_env_test.exs"],
  # Slow (every test runs git) and rarely changed: mutated only when they or their tests change.
  "lib/xeito/undo/store.ex" => [
    tests: ["test/xeito/undo_test.exs", "test/xeito/undo_env_test.exs"],
    only_when_changed: true
  ],
  "lib/xeito/undo/branch.ex" => ["test/xeito/undo_test.exs", "test/xeito/undo_env_test.exs"],
  "lib/xeito/undo/outside.ex" => [tests: ["test/xeito/undo_test.exs"], only_when_changed: true],
  # Which oversized files undo removes: a wrong one deletes a file the user made or changed.
  "lib/xeito/undo/created.ex" => ["test/xeito/undo_test.exs"],
  # What leaves a run for telemetry handlers, which may send it off the machine.
  "lib/xeito/telemetry.ex" => ["test/xeito/telemetry_test.exs"],
  "lib/xeito/tui.ex" => [tests: ["test/xeito/tui_test.exs"], section: "the prompt line"],
  "lib/xeito/tui/input.ex" => ["test/xeito/tui_test.exs", "test/xeito/tui/input_test.exs"]
}
