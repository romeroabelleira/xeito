defmodule Xeito.Session.Allowed do
  @moduledoc """
  The shell commands a review does not ask about again: those approved with `/approve session`
  (the TUI's `s`), held by the session until it closes, and those approved with
  `/approve always` (`a`), kept in the workspace's `.xeito/allowed.json`. Edit that file to
  take one back.

  A command is matched exactly, as the model wrote it, so an allowance never widens to a
  variant of it. An allowance only stands in for the human's `y`: the `Risk` decision still
  runs first, and a command it forbids is blocked whether or not it was allowed
  (`docs/architecture/10-security-and-sandboxing.md`).
  """

  @file_name "allowed.json"

  @type scope :: :session | :always
  @type session :: MapSet.t(String.t())

  @doc "No command allowed for the session yet."
  @spec new() :: session()
  def new, do: MapSet.new()

  @doc "The shell command a review is about, or `:error` when the review is not about one."
  @spec command(map() | nil) :: {:ok, String.t()} | :error
  def command(%{"tool" => "bash", "arguments" => %{"command" => command}}) when is_binary(command), do: {:ok, command}
  def command(_call), do: :error

  @doc "Why the review about `call` can be skipped: `:session` or `:always`, or `nil` when it cannot."
  @spec scope(Path.t(), session(), map() | nil) :: scope() | nil
  def scope(cwd, session, call) do
    case command(call) do
      {:ok, command} -> scope_of(command, session, cwd)
      :error -> nil
    end
  end

  defp scope_of(command, session, cwd) do
    cond do
      MapSet.member?(session, command) -> :session
      command in always(cwd) -> :always
      true -> nil
    end
  end

  @doc "Remembers `command`: in the session's set, or in the workspace's file."
  @spec remember(scope(), String.t(), Path.t(), session()) :: {:ok, session()} | {:error, File.posix()}
  def remember(:session, command, _cwd, session), do: {:ok, MapSet.put(session, command)}

  def remember(:always, command, cwd, session) do
    with :ok <- save(cwd, Enum.uniq(always(cwd) ++ [command])), do: {:ok, session}
  end

  @doc "The commands always allowed in the workspace, from its `.xeito/allowed.json`."
  @spec always(Path.t()) :: [String.t()]
  def always(cwd) do
    case File.read(path(cwd)) do
      {:ok, text} -> decode(text)
      {:error, _missing} -> []
    end
  end

  defp decode(text) do
    case JSON.decode(text) do
      {:ok, list} when is_list(list) -> Enum.filter(list, &is_binary/1)
      _not_a_list -> []
    end
  end

  # `.xeito` is the daemon's own and normally exists already (the log lives there); made here
  # as `Xeito.Log.for_workspace/1` makes it, so the project's git never sees it.
  defp save(cwd, commands) do
    dir = Path.join(cwd, ".xeito")

    with :ok <- File.mkdir_p(dir),
         :ok <- ignore(dir) do
      File.write(path(cwd), encode(commands))
    end
  end

  defp ignore(dir) do
    gitignore = Path.join(dir, ".gitignore")
    if File.exists?(gitignore), do: :ok, else: File.write(gitignore, "*\n")
  end

  # One command per line, so the file reads and edits well.
  defp encode(commands), do: "[\n" <> Enum.map_join(commands, ",\n", &("  " <> JSON.encode!(&1))) <> "\n]\n"

  defp path(cwd), do: Path.join([cwd, ".xeito", @file_name])
end
