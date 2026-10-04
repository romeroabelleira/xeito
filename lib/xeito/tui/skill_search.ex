defmodule Xeito.Tui.SkillSearch do
  @moduledoc """
  Finding a skill by what it does, in the TUI (P4f step 2): `/skills <words>` lists the
  workspace's and the user's skills that match, the best first (`Xeito.Skills.Index`, matching
  any word or a fragment of one), and `/skills` alone lists them all. After `/skill:`, Tab
  completes the names that start with what is typed, then the skills those words describe.
  """

  alias Xeito.Skills
  alias Xeito.Skills.Index
  alias Xeito.Tui

  @shown 10
  @description 100

  @doc "Runs `/skills` with its words, if any, appending the list to the TUI's lines."
  @spec command(String.t(), map()) :: map()
  def command(words, state),
    do: Tui.append(state, words |> lines(Skills.discover(state.cwd)) |> Enum.map_join(&(&1 <> "\n")))

  defp lines("", skills),
    do: ["#{length(skills)} skills (/skills <words> finds one by what it does):" | rows(Enum.sort_by(skills, & &1.name))]

  defp lines(words, skills) do
    case Index.search(skills, words, any: true, k: @shown) do
      [] -> [~s(no skill matches "#{words}" · /skills alone lists them all)]
      found -> [~s(skills for "#{words}", the best first:) | rows(found)]
    end
  end

  defp rows(skills), do: Enum.map(skills, &"  /skill:#{&1.name} · #{cut(&1.description)}")

  defp cut(text) do
    if String.length(text) <= @description, do: text, else: String.slice(text, 0, @description - 1) <> "…"
  end

  @doc "The skill names completing `part`: those it starts, then those whose skills it describes."
  @spec completions(String.t(), Path.t() | nil) :: [String.t()]
  def completions(part, cwd) do
    skills = Skills.discover(cwd)
    lower = String.downcase(part)

    starting =
      for skill <- Enum.sort_by(skills, & &1.name),
          String.starts_with?(String.downcase(skill.name), lower),
          do: skill.name

    Enum.uniq(starting ++ Enum.map(described(skills, part), & &1.name))
  end

  defp described(_skills, ""), do: []
  defp described(skills, part), do: Index.search(skills, part, any: true, k: @shown)
end
