defmodule Xeito.Skills do
  @moduledoc """
  Discovers and parses Agent Skills (`SKILL.md` directories) for the chat model.

  * Read from `<workspace>/.agents/skills/`, then `~/.agents/skills/`, recursively; on a name
    collision the first wins. No other tool's skill folders are read.
  * The frontmatter needs a `name` and a `description`; otherwise the skill is skipped.
  * A turn lists the workspace's skills in the prompt; the user's are shortlisted (`for_turn/3`)
    for a `Xeito.Decisions.Skill` decision. `/skill:name args` forces one.
  * `disable-model-invocation: true` keeps a skill out of lists and suggestions.
  * The `skill` tool reads only inside the skill's directory; scripts run through `bash`, so the
    `Risk` decision still applies.
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

  # `config :xeito, :skills_home` lets tests point it nowhere.
  defp user_home, do: Application.get_env(:xeito, :skills_home) || System.user_home() || "/nonexistent"

  @doc """
  The skills visible from a workspace, project skills first, with overlay keywords and cached
  examples added. Options: `:home` (user's home), `:keywords` (overlay file, default
  `XEITO_SKILL_KEYWORDS`; `nil` for none).
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
  An overlay file's keywords by skill name: one `name: word, word` line per skill, `#` comments.
  A missing file gives `%{}`.
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

  @doc "The prompt of a chat turn that runs `skill` for `request` (`/skill:name request`)."
  @spec invocation(t(), String.t()) :: String.t()
  def invocation(skill, request) do
    """
    Use the skill "#{skill.name}". Its directory is #{skill.dir}; paths in it are relative to
    that directory, and the skill tool reads its files. Instructions:

    #{body(skill)}

    Request: #{if request == "", do: "(none; follow the instructions)", else: request}
    """
  end

  @doc "The workspace's skills as `listed`, and up to three user skills as `candidates` (`shortlist/2`)."
  @spec for_turn([t()], Path.t(), String.t()) :: %{listed: [t()], candidates: [t()]}
  def for_turn(skills, cwd, request) do
    root = Path.join(Path.expand(cwd), ".agents/skills") <> "/"
    {listed, user} = Enum.split_with(skills, &String.starts_with?(&1.dir, root))
    %{listed: listed, candidates: shortlist(user, request)}
  end

  @doc "Up to three model-invocable skills ranked against the request (`Xeito.Skills.Index`)."
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

  defp nested([]), do: ""
  defp nested(lines), do: lines |> Enum.map(&String.trim_leading/1) |> parse_yaml(%{})

  defp unquote_value(<<q, _::binary>> = v) when q in [?", ?'] and byte_size(v) >= 2,
    do: binary_part(v, 1, byte_size(v) - 2)

  defp unquote_value(v), do: v
end
