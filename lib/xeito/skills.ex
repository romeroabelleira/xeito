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
  turn lists only the workspace's own skills: the user's are shortlisted by a full-text index
  (`for_turn/3`, `Xeito.Skills.Index`) and at most one is suggested per turn, by a typed decision
  (`Xeito.Decisions.Skill`, P4e). A skill with `disable-model-invocation: true` is never listed
  or suggested, only run by the explicit command. The `skill`
  tool reads files *inside that skill's directory only*; scripts it mentions run through `bash`,
  so the `Risk` decision still applies.
  """

  alias Xeito.Skills.Examples
  alias Xeito.Skills.Index

  @type t :: %{
          optional(:examples) => [String.t()],
          name: String.t(),
          description: String.t(),
          dir: Path.t(),
          model_invocation: boolean(),
          keywords: [String.t()]
        }

  @max_description 1_024

  # The home whose user skills are read: `config :xeito, :skills_home` (tests point it nowhere),
  # else the user's.
  defp user_home, do: Application.get_env(:xeito, :skills_home) || System.user_home() || "/nonexistent"

  @doc """
  The skills visible from a workspace, project skills first, with the keywords of the overlay
  file (`overlay/1`) added and their cached example requests (`Xeito.Skills.Examples`). `opts[:home]` overrides the user's home, `opts[:keywords]` the
  overlay file (by default `XEITO_SKILL_KEYWORDS`; `nil` for none).
  """
  @spec discover(Path.t(), keyword()) :: [t()]
  def discover(cwd, opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &user_home/0)
    overlay = overlay(Keyword.get_lazy(opts, :keywords, fn -> System.get_env("XEITO_SKILL_KEYWORDS") end))

    [Path.join(cwd, ".agents/skills"), Path.join(home, ".agents/skills")]
    |> from_dirs()
    |> add_keywords(overlay)
    |> Examples.attach()
  end

  @doc "Adds an overlay's keywords (`overlay/1`) to the skills it names."
  @spec add_keywords([t()], %{String.t() => [String.t()]}) :: [t()]
  def add_keywords(skills, overlay),
    do: Enum.map(skills, &%{&1 | keywords: Enum.uniq(&1.keywords ++ Map.get(overlay, &1.name, []))})

  @doc """
  An overlay file's keywords by skill name, for skills whose files are not yours to edit: one
  `name: word, word` line per skill; `#` starts a comment. No file, no keywords.
  """
  @spec overlay(Path.t() | nil) :: %{String.t() => [String.t()]}
  def overlay(nil), do: %{}

  def overlay(path) do
    case File.read(path) do
      {:ok, text} ->
        for [_, name, words] <- Regex.scan(~r/^([^#:\s][^:]*):(.*)$/m, text),
            into: %{},
            do: {String.trim(name), split(words)}

      {:error, _} ->
        %{}
    end
  end

  # A list of words, `[a, "b"]` or `a, b`.
  defp split(text) do
    text
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> unquote_value()))
    |> Enum.reject(&(&1 == ""))
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
          model_invocation: meta["disable-model-invocation"] not in ["true", "yes"],
          keywords: keywords(meta["metadata"])
        }
      ]
    else
      _ -> []
    end
  end

  defp name_and_description(%{"name" => name, "description" => desc})
       when is_binary(name) and name != "" and is_binary(desc) and desc != "", do: {:ok, name, desc}

  defp name_and_description(_meta), do: :error

  defp keywords(%{"keywords" => words}), do: split(words)
  defp keywords(_metadata), do: []

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
  to three of the user's skills as `candidates` for the turn's skill decision (`shortlist/2`).
  """
  @spec for_turn([t()], Path.t(), String.t()) :: %{listed: [t()], candidates: [t()]}
  def for_turn(skills, cwd, request) do
    root = Path.join(Path.expand(cwd), ".agents/skills") <> "/"
    {listed, user} = Enum.split_with(skills, &String.starts_with?(&1.dir, root))
    %{listed: listed, candidates: shortlist(user, request)}
  end

  @doc """
  The user's skills a turn may choose from: those the model may invoke, ranked against the
  request (`Xeito.Skills.Index`), at most three. `Xeito.Skills.Bench` measures it.
  """
  @spec shortlist([t()], String.t()) :: [t()]
  def shortlist(skills, request), do: skills |> Enum.filter(& &1.model_invocation) |> Index.search(request)

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
  # (`>` / `|`) for multi-line values. One nested level (`metadata:`) is read as a map.
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
      [_, key, value] ->
        {value, rest} = value(value, rest)
        parse_yaml(rest, Map.put(acc, key, value))

      nil ->
        parse_yaml(rest, acc)
    end
  end

  # A key's value, and the lines after it: a folded or literal block, a nested map, or the rest
  # of the line.
  defp value(style, rest) when style in [">", "|", ">-", "|-"] do
    {block, rest} = Enum.split_while(rest, &(String.starts_with?(&1, " ") or &1 == ""))
    joiner = if String.starts_with?(style, ">"), do: " ", else: "\n"
    {block |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.join(joiner), rest}
  end

  defp value("", rest) do
    {nested, rest} = Enum.split_while(rest, &String.starts_with?(&1, " "))
    {nested(nested), rest}
  end

  defp value(text, rest), do: {unquote_value(String.trim(text)), rest}

  # The indented `key: value` lines under a key without a value: its map (one level only).
  defp nested([]), do: ""
  defp nested(lines), do: lines |> Enum.map(&String.trim_leading/1) |> parse_yaml(%{})

  defp unquote_value(<<q, _::binary>> = v) when q in [?", ?'] and byte_size(v) >= 2,
    do: binary_part(v, 1, byte_size(v) - 2)

  defp unquote_value(v), do: v
end
