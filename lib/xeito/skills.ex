defmodule Xeito.Skills do
  @moduledoc """
  Discovers and parses Agent Skills (`SKILL.md` directories) for the chat model.

  * Read from `<workspace>/.agents/skills/`, then `~/.agents/skills/`, then the samples shipped
    with Xeito (`priv/skills`), recursively (`layers/2`); on a name collision the first wins and
    the rest are shadowed (`all/2`). No other tool's skill folders are read.
  * The frontmatter needs a `name` and a `description`; otherwise the skill is skipped. Under
    `metadata:` a skill may choose its chat `tier` and its `output` (`text`, or `json:<type>`),
    declare the `vars` its text takes (`lang=English, name`, filled through `fill/2`) and the
    named `contexts` it wants (`context/3`). An overlay line sets them for skills you can't edit
    (`name: word, tier=remote, output=json:triage`).
  * A turn lists the workspace's skills in the prompt; the user's are shortlisted (`for_turn/3`)
    for a `Xeito.Decisions.Skill` decision. `/skill:name args` forces one.
  * `disable-model-invocation: true` keeps a skill out of lists and suggestions.
  * The `skill` tool reads only inside the skill's directory; scripts run through `bash`, so the
    `Risk` decision still applies.
  """

  alias Xeito.Skills.Bench
  alias Xeito.Skills.Examples
  alias Xeito.Skills.Index

  @typedoc "Where a skill was found: the workspace, the user's home, or Xeito's samples."
  @type layer :: :project | :user | :sample

  @typedoc "What a skill answers with: prose, or JSON of a decision type."
  @type output :: :text | {:json, String.t()}

  @type t :: %{
          optional(:examples) => [String.t()],
          optional(:layer) => layer(),
          optional(:shadowed) => boolean(),
          optional(:tier) => String.t() | nil,
          optional(:output) => output(),
          optional(:vars) => %{String.t() => String.t() | nil},
          optional(:contexts) => [String.t()],
          name: String.t(),
          description: String.t(),
          dir: Path.t(),
          model_invocation: boolean(),
          keywords: [String.t()]
        }

  @max_description 1_024

  # `config :xeito, :skills_home` and `:skills_sample` let tests point them nowhere.
  defp user_home, do: Application.get_env(:xeito, :skills_home) || System.user_home() || "/nonexistent"
  defp sample_dir, do: Application.get_env(:xeito, :skills_sample) || Bench.sample_skills()

  @doc """
  The skills visible from a workspace, in layer order and the first of a name only, with the
  overlay applied and cached examples added. Options: `:home` (user's home), `:sample` (the
  samples' directory), `:keywords` (overlay file, default `XEITO_SKILL_KEYWORDS`; `nil` for none).
  """
  @spec discover(Path.t(), keyword()) :: [t()]
  def discover(cwd, opts \\ []) do
    overlay = overlay(Keyword.get_lazy(opts, :keywords, fn -> System.get_env("XEITO_SKILL_KEYWORDS") end))

    cwd
    |> all(opts)
    |> Enum.reject(& &1.shadowed)
    |> apply_overlay(overlay)
    |> Examples.attach()
  end

  @doc "Every skill under the layers (`layers/2`), each with its `layer`, and `shadowed` when an earlier layer has its name."
  @spec all(Path.t(), keyword()) :: [t()]
  def all(cwd, opts \\ []) do
    cwd
    |> layers(opts)
    |> Enum.flat_map(fn {layer, root} -> [root] |> from_dirs() |> Enum.map(&Map.put(&1, :layer, layer)) end)
    |> Enum.map_reduce(MapSet.new(), fn skill, seen ->
      {Map.put(skill, :shadowed, MapSet.member?(seen, skill.name)), MapSet.put(seen, skill.name)}
    end)
    |> elem(0)
  end

  @doc "The skill directories read from a workspace, in order: the project's, the user's, Xeito's samples."
  @spec layers(Path.t(), keyword()) :: [{layer(), Path.t()}]
  def layers(cwd, opts \\ []) do
    [
      project: Path.join(cwd, ".agents/skills"),
      user: Path.join(Keyword.get_lazy(opts, :home, &user_home/0), ".agents/skills"),
      sample: Keyword.get_lazy(opts, :sample, &sample_dir/0)
    ]
  end

  @doc """
  Applies an overlay (`overlay/1`) to the skills it names: its words become keywords, and a
  `tier=NAME` or `output=text|json:<type>` word sets that choice.
  """
  @spec apply_overlay([t()], %{String.t() => [String.t()]}) :: [t()]
  def apply_overlay(skills, overlay), do: Enum.map(skills, &overlaid(&1, Map.get(overlay, &1.name, [])))

  defp overlaid(skill, words) do
    {settings, keywords} = Enum.split_with(words, &String.contains?(&1, "="))

    Enum.reduce(settings, %{skill | keywords: Enum.uniq(skill.keywords ++ keywords)}, fn
      "tier=" <> tier, s -> Map.put(s, :tier, tier)
      "output=" <> output, s -> Map.put(s, :output, output(output))
      _other, s -> s
    end)
  end

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
        Map.merge(settings(meta["metadata"]), %{
          name: name,
          description: String.slice(desc, 0, @max_description),
          dir: Path.dirname(file),
          model_invocation: meta["disable-model-invocation"] not in ["true", "yes"],
          keywords: keywords(meta["metadata"])
        })
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

  # The skill's choices under `metadata:`: its tier, output, declared variables and contexts.
  defp settings(%{} = m) do
    %{tier: m["tier"], output: output(m["output"]), vars: vars(m["vars"]), contexts: split(m["contexts"] || "")}
  end

  defp settings(_metadata), do: %{tier: nil, output: :text, vars: %{}, contexts: []}

  defp output("json:" <> type), do: {:json, type}
  defp output(_text), do: :text

  # `lang=English, name`: a default after `=`, or none.
  defp vars(nil), do: %{}

  defp vars(text) do
    Map.new(split(text), fn declaration ->
      case String.split(declaration, "=", parts: 2) do
        [name, default] -> {name, default}
        [name] -> {name, nil}
      end
    end)
  end

  @doc """
  The skill's instructions with each `{{name}}` filled: a given value first, else the declared
  default. A declared variable without either is an error before any model call; a `{{name}}`
  the skill does not declare is left alone.
  """
  @spec fill(t(), %{String.t() => String.t()}) :: {:ok, String.t()} | {:error, String.t()}
  def fill(skill, vars) do
    values = Map.merge(Map.get(skill, :vars, %{}), vars)

    case Enum.find(values, fn {_name, value} -> value == nil end) do
      {name, nil} -> {:error, "the skill #{skill.name} needs a value for {{#{name}}} (#{name}=VALUE)"}
      nil -> {:ok, Enum.reduce(values, body(skill), fn {k, v}, text -> String.replace(text, "{{#{k}}}", v) end)}
    end
  end

  @doc """
  A named context: `<workspace>/.agents/contexts/NAME.md`, else `~/.agents/contexts/NAME.md`
  (option `:home`), trimmed; `:error` for none, or a name that is not a plain file name.
  """
  @spec context(Path.t(), String.t(), keyword()) :: {:ok, String.t()} | :error
  def context(cwd, name, opts \\ []) do
    if Regex.match?(~r/^[\w][\w.-]*$/, name) do
      [cwd, Keyword.get_lazy(opts, :home, &user_home/0)]
      |> Enum.map(&Path.join([&1, ".agents/contexts", name <> ".md"]))
      |> Enum.find_value(:error, &read_context/1)
    else
      :error
    end
  end

  defp read_context(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, String.trim(text)}
      {:error, _} -> nil
    end
  end

  @doc "The instructions of `SKILL.md` without its frontmatter."
  @spec body(t()) :: String.t()
  def body(skill) do
    text = File.read!(Path.join(skill.dir, "SKILL.md"))

    case String.split(text, ~r/^---\s*$/m, parts: 3) do
      ["", _meta, body] -> String.trim(body)
      _ -> String.trim(text)
    end
  end

  @doc "The prompt of a chat turn that runs `skill` for `request` (`/skill:name request`), its variables filled (`fill/2`)."
  @spec invocation(t(), String.t(), %{String.t() => String.t()}) :: {:ok, String.t()} | {:error, String.t()}
  def invocation(skill, request, vars \\ %{}) do
    with {:ok, instructions} <- fill(skill, vars) do
      {:ok,
       """
       Use the skill "#{skill.name}". Its directory is #{skill.dir}; paths in it are relative to
       that directory, and the skill tool reads its files. Instructions:

       #{instructions}

       Request: #{if request == "", do: "(none; follow the instructions)", else: request}
       """}
    end
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
