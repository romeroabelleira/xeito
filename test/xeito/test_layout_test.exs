defmodule Xeito.TestLayoutTest do
  # A module's tests are where an agent looks first: `test/<path>_test.exs` for `lib/<path>.ex`
  # (and `test/support/<path>.ex`). A mix task `lib/mix/tasks/xeito.a.b.ex` is tested in
  # `test/mix/tasks/xeito_a_b_test.exs`. Tests that exercise several modules together are named
  # for the behaviour they check and listed here, each with what it covers.
  use ExUnit.Case, async: true

  @spanning %{
    "test/xeito/architecture_test.exs" => "dependency rules between layers, from compiled calls",
    "test/xeito/glossary_test.exs" => "GLOSSARY.md against the modules",
    "test/xeito/harness_test.exs" => "the tools, a client and its transcript against a running session",
    "test/xeito/machines_test.exs" => "the built-in machines, skills and tool refusals through the runner",
    "test/xeito/repo_skills_test.exs" => "the repository's own skills, AGENTS.md and CLAUDE.md",
    "test/xeito/risk_property_test.exs" => "Risk's rules over generated commands, in a fixture workspace",
    "test/xeito/run_property_test.exs" => "the log alone reproduces a run, for random event sequences",
    "test/xeito/session_commands_test.exs" => "a session's slash commands",
    "test/xeito/session_queue_test.exs" => "lines typed while a turn runs",
    "test/xeito/skill_keywords_test.exs" => "skill keywords from frontmatter and the overlay, in the index",
    "test/xeito/skills_per_turn_test.exs" => "a turn's skill shortlist, decision and suggestion",
    "test/xeito/step_test.exs" => "step mode and breakpoints across runs",
    "test/xeito/test_git_config_test.exs" => "the tests' own git config, also through erlexec",
    "test/xeito/test_layout_test.exs" => "this layout",
    "test/xeito/undo_env_test.exs" => "undo inside a git hook's environment"
  }

  defp test_files, do: Path.wildcard("test/**/*_test.exs")

  # The source file a test file mirrors.
  defp source("test/mix/tasks/" <> name),
    do: "lib/mix/tasks/" <> String.replace(String.replace_suffix(name, "_test.exs", ""), "_", ".") <> ".ex"

  defp source("test/" <> path), do: "lib/" <> String.replace_suffix(path, "_test.exs", ".ex")

  defp mirrors?(test) do
    lib = source(test)
    File.exists?(lib) or File.exists?(String.replace_prefix(lib, "lib/", "test/support/"))
  end

  test "every test file mirrors a source file, or is a listed test of several modules" do
    stray = for t <- test_files(), not mirrors?(t), not Map.has_key?(@spanning, t), do: t

    assert stray == [],
           "move these to test/<path>_test.exs for lib/<path>.ex, or list them in @spanning with what they cover:\n  " <>
             Enum.join(stray, "\n  ")
  end

  test "the list of tests of several modules names only files that exist and mirror nothing" do
    for {t, _covers} <- @spanning do
      assert File.exists?(t), "#{t} is listed but does not exist"
      refute mirrors?(t), "#{t} mirrors #{source(t)}: remove it from @spanning"
    end
  end

  test "the mirror of a path" do
    assert source("test/xeito/chat/window_test.exs") == "lib/xeito/chat/window.ex"
    assert source("test/mix/tasks/xeito_skills_bench_test.exs") == "lib/mix/tasks/xeito.skills.bench.ex"
  end
end
