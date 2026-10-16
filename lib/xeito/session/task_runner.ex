defmodule Xeito.Session.TaskRunner do
  @moduledoc """
  Finds a command in the project's own task runner: `justfile` recipes first, then `mise.toml` tasks.

  * A runner that is not installed is skipped.
  * Read with patterns, not parsers: a just recipe is a line `name …:` (not `:=`); a mise task
    is a `[tasks.<name>]` table or a key in `[tasks]`.
  """

  alias Xeito.Executables

  @runners [
    {"just", ~w(justfile Justfile .justfile), "just "},
    {"mise", ~w(mise.toml .mise.toml), "mise run "}
  ]

  @doc "The command for the first of `names` the workspace's task runner defines, or `nil`."
  @spec command(Path.t(), [String.t()]) :: String.t() | nil
  def command(cwd, names) do
    Enum.find_value(@runners, fn {runner, files, prefix} ->
      with path when is_binary(path) <- Executables.find(runner),
           text when is_binary(text) <- first_file(cwd, files),
           name when is_binary(name) <- Enum.find(names, &(&1 in tasks(runner, text))) do
        prefix <> name
      end
    end)
  end

  defp first_file(cwd, files) do
    Enum.find_value(files, fn file ->
      case File.read(Path.join(cwd, file)) do
        {:ok, text} -> text
        {:error, _} -> nil
      end
    end)
  end

  defp tasks("just", text),
    do: for([_, name] <- Regex.scan(~r/^@?([A-Za-z_][\w-]*)(?:[ \t][^:\n]*)?:(?!=)/m, text), do: name)

  defp tasks("mise", text) do
    text
    |> String.split("\n")
    |> Enum.reduce({nil, []}, &mise_line/2)
    |> elem(1)
  end

  # `{current table, tasks so far}`: a table header changes the table; a key counts in `[tasks]`.
  defp mise_line(line, {table, tasks}) do
    case Regex.run(~r/^\s*\[([^\]]+)\]\s*$/, line) do
      [_, header] -> {header, tasks ++ task_table(header)}
      nil -> {table, tasks ++ task_key(table, line)}
    end
  end

  defp task_table(header) do
    case Regex.run(~r/^tasks\.(?:"([^"]+)"|([\w-]+))$/, String.trim(header)) do
      [_, quoted] -> [quoted]
      [_, "", bare] -> [bare]
      nil -> []
    end
  end

  defp task_key("tasks", line) do
    case Regex.run(~r/^\s*"?([\w-]+)"?\s*=/, line) do
      [_, name] -> [name]
      nil -> []
    end
  end

  defp task_key(_table, _line), do: []
end
