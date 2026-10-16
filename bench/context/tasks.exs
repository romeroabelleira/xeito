# Typical tasks on this repository, with the files an agent reads to do each: the module it
# changes, what that module leans on, and the tests that pin it. `mix xeito.context` reports what
# each costs in tokens (P4i). Keep the tasks; update the paths when files move, so the numbers
# stay comparable.
%{
  # Read for every task: Claude Code loads CLAUDE.md, which imports AGENTS.md.
  always: ["CLAUDE.md", "AGENTS.md", "GLOSSARY.md"],
  tasks: [
    %{
      name: "add a slash command",
      files: ["lib/xeito/session.ex", "test/xeito/session_commands_test.exs"]
    },
    %{
      name: "change a decision type's rules (Risk)",
      files: ["lib/xeito/decisions/risk.ex", "lib/xeito/decision.ex", "test/xeito/decision_test.exs"]
    },
    %{
      name: "fix a status bar segment",
      files: ["lib/xeito/client/status_bar.ex", "test/xeito/client/status_bar_test.exs"]
    },
    %{
      name: "add a tier setting",
      files: ["lib/xeito/tiers/settings.ex", "lib/xeito/tiers.ex", "test/xeito/tiers/settings_test.exs"]
    },
    %{
      name: "add a chat tool",
      files: ["lib/xeito/tools.ex", "lib/xeito/effect.ex", "lib/xeito/effects/local.ex", "test/xeito/tools_test.exs"]
    },
    %{
      name: "change the chat machine's step limit",
      files: ["lib/xeito/machines/chat.ex", "test/xeito/chat_machine_test.exs"]
    },
    %{
      name: "change how requests fit the context window",
      files: ["lib/xeito/chat/window.ex", "test/xeito/chat_window_test.exs"]
    },
    %{
      name: "add a TUI key binding",
      files: ["lib/xeito/tui.ex", "test/xeito/tui_test.exs"]
    },
    %{
      name: "add a machine",
      files: [
        "lib/xeito/machine.ex",
        "lib/xeito/machines/run_tests.ex",
        "lib/xeito/session/router.ex",
        "test/xeito/machines_test.exs"
      ]
    },
    %{
      name: "change the remote chat spend gate",
      files: ["lib/xeito/allowance.ex", "lib/xeito/chat.ex", "test/xeito/allowance_test.exs"]
    }
  ]
}
