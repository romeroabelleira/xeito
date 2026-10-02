defmodule Xeito.RepoSkillsTest do
  @moduledoc """
  The repository's own skills (`.agents/skills/`) follow its skill convention
  (`.agents/skills/README.md`): valid frontmatter, written for any agent, and a vendored skill
  keeps its license and lists what was changed.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../.agents/skills", __DIR__)
  @skill_dirs @root |> Path.join("*/SKILL.md") |> Path.wildcard() |> Enum.map(&Path.dirname/1) |> Enum.sort()

  # Commands of one particular agent or terminal, which the convention keeps out of skills.
  @tool_specific [~r/\bclaude -p\b/, ~r/\bunbuffer\b/, ~r/\.claude\//]

  test "the repository has skills" do
    assert Enum.map(@skill_dirs, &Path.basename/1) == ~w(elixir otp skill-authoring)
  end

  for dir <- @skill_dirs do
    @dir dir
    @name Path.basename(dir)

    test "#{@name}: loads, named after its directory, with a description" do
      assert [%{name: @name, description: description}] = Xeito.Skills.load(Path.join(@dir, "SKILL.md"))
      assert String.length(description) in 40..1_024
    end

    test "#{@name}: no commands of a particular agent or terminal" do
      text = File.read!(Path.join(@dir, "SKILL.md"))
      assert Enum.filter(@tool_specific, &Regex.match?(&1, text)) == []
    end

    test "#{@name}: if vendored, its license and the changes made here" do
      attribution = Path.join(@dir, "ATTRIBUTION.md")

      if File.exists?(attribution) do
        assert File.exists?(Path.join(@dir, "LICENSE"))
        text = File.read!(attribution)
        assert text =~ ~r/upstream commit `[0-9a-f]{40}`/i
        assert text =~ "## Changes"
        assert File.read!(Path.join(@dir, "SKILL.md")) =~ "Adapted for this repository"
      end
    end
  end
end
