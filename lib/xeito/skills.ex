defmodule Xeito.Skills do
  @moduledoc """
  Agent Skills (`SKILL.md` directories, https://agentskills.io/specification), the format pi
  uses too.

  Discovery, first match wins on a name collision (project before user):

    * `<workspace>/.agents/skills/`
    * `~/.agents/skills/`

  Only `.agents/skills`, the folder no single tool owns. Another harness's own folders (pi's
  `.pi/skills`, `~/.pi/agent/skills`) are not read, so what Xeito sees does not depend on what
  another tool has installed.

  Directories containing `SKILL.md` are found recursively. The frontmatter must have a `name` and
  a `description`; skills without a description are skipped, as in pi.

  As in pi, only names and descriptions go into the chat model's prompt, and the model loads a
  skill with the `skill` tool when a task matches; `/skill:name args` forces one. Unlike pi, a
  turn lists only the workspace's own skills: the user's are shortlisted by keyword
  (`for_turn/3`, `rank/3`) and at most one is suggested per turn, by a typed decision
  (`Xeito.Decisions.Skill`, P4e). A skill with `disable-model-invocation: true` is never listed
  or suggested, only run by the explicit command. The `skill`
  tool reads files *inside that skill's directory only*; scripts it mentions run through `bash`,
  so the `Risk` decision still applies.
  """

  @type t :: %{
          name: String.t(),
          description: String.t(),
          dir: Path.t(),
          model_invocation: boolean()
        }

  @max_description 1_024

  # The home whose user skills are read: `config :xeito, :skills_home` (tests point it nowhere),
  # else the user's.
  defp user_home, do: Application.get_env(:xeito, :skills_home) || System.user_home() || "/nonexistent"

  @doc "The skills visible from a workspace, project skills first. `opts[:home]` overrides the user's home."
  @spec discover(Path.t(), keyword()) :: [t()]
  def discover(cwd, opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &user_home/0)

    from_dirs([Path.join(cwd, ".agents/skills"), Path.join(home, ".agents/skills")])
  end

  @doc "The directory of the user's skills."
  @spec user_dir() :: Path.t()
  def user_dir, do: Path.join(user_home(), ".agents/skills")

  @doc "The skills under the directories, searched recursively in order; the first of a name wins."
  @spec from_dirs([Path.t()]) :: [t()]
  def from_dirs(roots) do
    roots
    |> Enum.flat_map(&(&1 |> Path.join("**/SKILL.md") |> Path.wildcard() |> Enum.sort()))
    |> Enum.flat_map(&load/1)
    |> Enum.uniq_by(& &1.name)
  end

  @doc "Parses one `SKILL.md`. Returns `[skill]`, or `[]` if it is not a valid skill."
  @spec load(Path.t()) :: [t()]
  def load(file) do
    with {:ok, text} <- File.read(file),
         {:ok, meta} <- frontmatter(text),
         {:ok, name, desc} <- name_and_description(meta) do
      [
        %{
          name: name,
          description: String.slice(desc, 0, @max_description),
          dir: Path.dirname(file),
          model_invocation: meta["disable-model-invocation"] not in ["true", "yes"]
        }
      ]
    else
      _ -> []
    end
  end

  defp name_and_description(%{"name" => name, "description" => desc})
       when is_binary(name) and name != "" and is_binary(desc) and desc != "", do: {:ok, name, desc}

  defp name_and_description(_meta), do: :error

  @doc "The instructions of `SKILL.md` without its frontmatter."
  @spec body(t()) :: String.t()
  def body(skill) do
    text = File.read!(Path.join(skill.dir, "SKILL.md"))

    case String.split(text, ~r/^---\s*$/m, parts: 3) do
      ["", _meta, body] -> String.trim(body)
      _ -> String.trim(text)
    end
  end

  @doc """
  What a chat turn offers the model: the workspace's own skills, `listed` in its prompt, and up
  to three of the user's skills as `candidates` for the turn's skill decision, shortlisted by
  `rank/3` against the request.
  """
  @spec for_turn([t()], Path.t(), String.t()) :: %{listed: [t()], candidates: [t()]}
  def for_turn(skills, cwd, request) do
    root = Path.join(Path.expand(cwd), ".agents/skills") <> "/"
    {listed, user} = Enum.split_with(skills, &String.starts_with?(&1.dir, root))
    %{listed: listed, candidates: shortlist(user, request)}
  end

  @doc """
  The user's skills a turn may choose from: those the model may invoke, ranked against the
  request (`rank/3`). `Xeito.Skills.Bench` measures it.
  """
  @spec shortlist([t()], String.t()) :: [t()]
  def shortlist(skills, request), do: skills |> Enum.filter(& &1.model_invocation) |> rank(request)

  # Words too common to say what a request is about.
  @common ~w(the and for with this that from into when what which where why how use used user users
             want wants need needs please can could should would will just about also any all some
             its are was were been have has had does did not you your our their them they then than
             there here make made get got one two new old way ways like more most less very much many
             each other only own same such too out over under after before while because between
             through during without within upon let lets now see say says)

  @doc """
  The skills that share at least two words with a request, the best first, at most `k`. A word of
  the skill's name counts double, a word of its description once; common words do not count.
  """
  @spec rank([t()], String.t(), pos_integer()) :: [t()]
  def rank(skills, request, k \\ 3) do
    words = words(request)

    skills
    |> Enum.map(&{shared(&1, words), &1})
    |> Enum.filter(fn {{_score, count}, _skill} -> count >= 2 end)
    |> Enum.sort_by(fn {{score, _count}, skill} -> {-score, skill.name} end)
    |> Enum.take(k)
    |> Enum.map(fn {_shared, skill} -> skill end)
  end

  # `{score, distinct words shared}` between a skill and a request's words.
  defp shared(skill, words) do
    name = MapSet.intersection(words, words(skill.name))
    description = words |> MapSet.intersection(words(skill.description)) |> MapSet.difference(name)
    {2 * MapSet.size(name) + MapSet.size(description), MapSet.size(name) + MapSet.size(description)}
  end

  defp words(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @common))
    |> MapSet.new()
  end

  @doc "The system-prompt section listing skills the model may load itself (empty if none)."
  @spec prompt_section([t()]) :: String.t()
  def prompt_section(skills) do
    case Enum.filter(skills, & &1.model_invocation) do
      [] ->
        ""

      listed ->
        lines = Enum.map_join(listed, "\n", &"- #{&1.name}: #{&1.description}")

        "\nSkills (load one with the skill tool before a task it describes; " <>
          "its files are relative to its directory):\n" <> lines <> "\n"
    end
  end

  # A minimal YAML subset: `key: value` lines, optional quotes, and folded or literal blocks
  # (`>` / `|`) for multi-line values. Nested maps (`metadata:`) are skipped.
  @doc false
  def frontmatter(text) do
    case String.split(text, ~r/^---\s*$/m, parts: 3) do
      ["", yaml, _body] -> {:ok, parse_yaml(String.split(yaml, "\n"), %{})}
      _ -> :error
    end
  end

  defp parse_yaml([], acc), do: acc

  defp parse_yaml([line | rest], acc) do
    case Regex.run(~r/^([A-Za-z][\w-]*):\s*(.*)$/, line) do
      [_, key, value] when value in [">", "|", ">-", "|-"] ->
        {block, rest} = Enum.split_while(rest, &(String.starts_with?(&1, " ") or &1 == ""))
        joiner = if String.starts_with?(value, ">"), do: " ", else: "\n"
        text = block |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join(joiner)
        parse_yaml(rest, Map.put(acc, key, text))

      [_, key, value] ->
        parse_yaml(rest, Map.put(acc, key, unquote_value(String.trim(value))))

      nil ->
        parse_yaml(rest, acc)
    end
  end

  defp unquote_value(<<q, _::binary>> = v) when q in [?", ?'] and byte_size(v) >= 2,
    do: binary_part(v, 1, byte_size(v) - 2)

  defp unquote_value(v), do: v
end
