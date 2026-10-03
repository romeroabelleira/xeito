defmodule Xeito.Skills do
  @moduledoc """
  Agent Skills (`SKILL.md` directories), read in pi's format (https://agentskills.io/specification).

  Discovery, first match wins on a name collision (project before user):

    * `<workspace>/.pi/skills/`, `<workspace>/.agents/skills/`
    * `~/.pi/agent/skills/`, `~/.agents/skills/`

  Directories containing `SKILL.md` are found recursively. The frontmatter must have a `name` and
  a `description`; skills without a description are skipped, as in pi.

  As in pi, only names and descriptions go into the chat model's system prompt. The model loads
  a skill with the `skill` tool when a task matches, and `/skill:name args` forces one. A skill
  with `disable-model-invocation: true` is listed only for the explicit command. The `skill`
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

    roots = [
      Path.join(cwd, ".pi/skills"),
      Path.join(cwd, ".agents/skills"),
      Path.join(home, ".pi/agent/skills"),
      Path.join(home, ".agents/skills")
    ]

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
