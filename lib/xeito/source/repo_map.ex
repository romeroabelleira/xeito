defmodule Xeito.Source.RepoMap do
  @moduledoc """
  A compact map of a project for a chat turn's instructions, so the model starts out knowing
  what kind of project it is in and where things live, instead of spending steps on `find` and
  `grep` (as in Aider's repository map, without its ranking).

    * the project kind (from its build files) and top-level directories;
    * for Elixir projects: every module under `lib/` (and `apps/*/lib/`) with its file, the first
      line of its moduledoc and its public functions, parsed by `Xeito.Source`;
    * the dependencies, and where their sources are.

  The map is capped at `@budget` characters: function lists go first, then modules are cut
  with a count of those left out. The text depends only on modules, their docs and public
  functions, so ordinary edits leave it (and the model's prompt cache) unchanged.
  """

  alias Xeito.Source

  @budget 6_000
  @kinds [
    {"mix.exs", "Elixir (Mix)"},
    {"package.json", "JavaScript/TypeScript (npm)"},
    {"Cargo.toml", "Rust (Cargo)"},
    {"go.mod", "Go"},
    {"pyproject.toml", "Python"},
    {"setup.py", "Python"},
    {"Gemfile", "Ruby"}
  ]

  @doc "The map as text, or `nil` when the directory has nothing to map."
  @spec build(Path.t(), pos_integer()) :: String.t() | nil
  def build(cwd, budget \\ @budget) do
    kinds = for {file, kind} <- @kinds, File.exists?(Path.join(cwd, file)), do: kind

    if kinds == [] and sources(cwd) == [] do
      nil
    else
      head = header(cwd, kinds)
      modules = modules(cwd)
      deps = deps_line(cwd)
      fit(head, modules, deps, budget)
    end
  end

  defp header(cwd, kinds) do
    dirs =
      case File.ls(cwd) do
        {:ok, names} ->
          names
          |> Enum.filter(&(File.dir?(Path.join(cwd, &1)) and not String.starts_with?(&1, ".")))
          |> Enum.reject(&(&1 in ["_build", "node_modules", "target"]))
          |> Enum.sort()
          |> Enum.map_join(" ", &(&1 <> "/"))

        _ ->
          ""
      end

    kind = if kinds == [], do: "Project", else: Enum.join(kinds, " + ") <> " project"
    "#{kind}. Top level: #{dirs}"
  end

  defp sources(cwd) do
    ["lib/**/*.ex", "apps/*/lib/**/*.ex"]
    |> Enum.flat_map(&Path.wildcard(Path.join(cwd, &1)))
    |> Enum.map(&Path.relative_to(&1, cwd))
    |> Enum.sort()
  end

  # `{line, functions}` per module, in file order.
  defp modules(cwd) do
    for file <- sources(cwd),
        {:ok, content} <- [File.read(Path.join(cwd, file))],
        {:ok, entries} <- [Source.entries(file, content)],
        module <- Enum.filter(entries, &(&1.kind == :defmodule)) do
      funs =
        for e <- entries,
            e.kind in [:def, :defmacro, :defdelegate, :defguard] and e.module == module.name,
            uniq: true,
            do: e.name

      {"#{module.name}  #{file}#{doc(content, module)}", funs}
    end
  end

  # The first line of a module's @moduledoc, if it is right there (a heredoc or a string).
  defp doc(content, module) do
    lines = content |> String.split("\n") |> Enum.drop(module.first) |> Enum.take(3)

    case Enum.find_index(lines, &String.contains?(&1, "@moduledoc")) do
      nil ->
        ""

      i ->
        line = Enum.at(lines, i)

        text =
          if String.contains?(line, ~s(""")),
            do: Enum.at(lines, i + 1, ""),
            else: line |> String.split("@moduledoc", parts: 2) |> List.last()

        case text |> String.trim() |> String.trim(~s(")) |> String.slice(0, 90) do
          "" -> ""
          "false" -> ""
          first -> " — " <> first
        end
    end
  end

  defp deps_line(cwd) do
    deps =
      cond do
        File.dir?(Path.join(cwd, "deps")) ->
          cwd |> Path.join("deps") |> File.ls!() |> Enum.sort()

        File.exists?(Path.join(cwd, "package.json")) ->
          with {:ok, text} <- File.read(Path.join(cwd, "package.json")),
               {:ok, %{} = pkg} <- JSON.decode(text) do
            pkg |> Map.get("dependencies", %{}) |> Map.keys() |> Enum.sort()
          else
            _ -> []
          end

        true ->
          []
      end

    case deps do
      [] ->
        nil

      deps ->
        "Dependencies (sources in deps/<name>/lib, read-only): " <>
          Enum.join(Enum.take(deps, 40), ", ")
    end
  end

  # The fullest form that fits: with functions, with docs, names and files only, or cut.
  defp fit(head, modules, deps, budget) do
    intro =
      "Project map (generated; for Elixir files, read with outline: true or symbol: \"name/arity\" " <>
        "to see more, instead of grep):\n" <> head

    Enum.find_value([:full, :docs, :names], fn mode ->
      text = render(intro, modules, deps, mode)
      if String.length(text) <= budget, do: text
    end) || cut(intro, modules, deps, budget)
  end

  defp render(intro, modules, deps, mode) do
    lines =
      Enum.flat_map(modules, fn {line, funs} ->
        case mode do
          :full when funs != [] -> ["  " <> line, "    " <> Enum.join(funs, " ")]
          :names -> ["  " <> (line |> String.split(" — ", parts: 2) |> hd())]
          _ -> ["  " <> line]
        end
      end)

    section = if lines == [], do: [], else: ["Modules:" | lines]
    Enum.join([intro | section] ++ List.wrap(deps), "\n")
  end

  defp cut(intro, modules, deps, budget) do
    room = budget - String.length(intro) - String.length(deps || "") - 60

    {kept, _} =
      Enum.reduce_while(modules, {[], 0}, fn {line, _}, {acc, used} ->
        used = used + (line |> String.split(" — ", parts: 2) |> hd() |> String.length()) + 3
        if used > room, do: {:halt, {acc, used}}, else: {:cont, {[{line, []} | acc], used}}
      end)

    kept = Enum.reverse(kept)

    more =
      "  … #{length(modules) - length(kept)} more modules; list them with find lib -name '*.ex'"

    render(intro, kept, nil, :names) <> "\n" <> more <> if(deps, do: "\n" <> deps, else: "")
  end
end
