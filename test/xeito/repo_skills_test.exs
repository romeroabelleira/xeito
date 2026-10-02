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
    assert Enum.map(@skill_dirs, &Path.basename/1) == ~w(elixir otp skill-authoring xeito-machine xeito-quality-gate)
  end

  @repo Path.expand("../..", __DIR__)

  test "every skill is listed in CLAUDE.md and in the skills README" do
    claude = File.read!(Path.join(@repo, "CLAUDE.md"))
    readme = File.read!(Path.join(@root, "README.md"))

    for name <- Enum.map(@skill_dirs, &Path.basename/1) do
      assert claude =~ "(.agents/skills/#{name}/SKILL.md)", "CLAUDE.md does not list #{name}"
      assert readme =~ "(#{name}/SKILL.md)", "the README does not list #{name}"
    end
  end

  for dir <- @skill_dirs do
    @dir dir
    @name Path.basename(dir)

    test "#{@name}: loads, named after its directory, with a description" do
      assert [%{name: @name, description: description}] = Xeito.Skills.load(Path.join(@dir, "SKILL.md"))
      assert String.length(description) in 40..1_024
    end

    test "#{@name}: the files and mix tasks it names exist" do
      text = File.read!(Path.join(@dir, "SKILL.md"))

      paths =
        for [_, path] <-
              Regex.scan(~r/`((?:lib|test|docs|scripts|bench|priv|config|\.agents)\/[^`\s*<]+?)(?::\d+)?`/, text),
            do: path

      assert Enum.reject(paths, &File.exists?(Path.join(@repo, &1))) == []

      tasks = for [_, task] <- Regex.scan(~r/`mix (xeito\.[a-z_.]+)/, text), uniq: true, do: task
      assert Enum.reject(tasks, &Mix.Task.get/1) == []
    end

    test "#{@name}: the complete modules it shows compile" do
      text = File.read!(Path.join(@dir, "SKILL.md"))

      for [_, code] <- Regex.scan(~r/```elixir\n(defmodule .*?)```/s, text) do
        modules = Code.compile_string(code, "#{@name}/SKILL.md")

        for {module, _} <- modules do
          :code.purge(module)
          :code.delete(module)
        end
      end
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
