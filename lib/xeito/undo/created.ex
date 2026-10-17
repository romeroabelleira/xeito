defmodule Xeito.Undo.Created do
  @moduledoc """
  Files over the snapshot size limit that a step created: undo removes them, while they are still as the step left it.

  * `find/3` names the oversized files after a step that existed neither as oversized files nor
    in the snapshot before it, with their size and mtime.
  * `plan/2` is what undo removes, or `{:error, {:created_changed, step, path}}` when a file's
    size or mtime moved since the step: then nothing changes. A file already gone is fine.
  * Redo cannot bring such a file back, as it was never captured; the step names it as skipped.
  """

  alias Xeito.Undo.Store

  @type entry :: %{path: Path.t(), size: non_neg_integer(), mtime: integer()}

  @doc "The oversized files in `big_after` that the step created, given the snapshot before it."
  @spec find(Path.t(), {String.t(), map()}, map()) :: [entry()]
  def find(cwd, {before_tree, big_before}, big_after) do
    for {path, _stat} <- big_after,
        not Map.has_key?(big_before, path),
        not in_tree?(cwd, before_tree, path),
        {:ok, %File.Stat{size: size, mtime: mtime}} <- [File.stat(Path.join(cwd, path), time: :posix)],
        do: %{path: path, size: size, mtime: mtime}
  end

  defp in_tree?(cwd, tree, path), do: match?({_, 0}, Store.git(cwd, ["cat-file", "-e", "#{tree}:#{path}"]))

  @spec lines([entry()]) :: [String.t()]
  def lines(entries), do: Enum.map(entries, &"created: #{&1.size} #{&1.mtime} #{&1.path}")

  @spec parse(String.t()) :: [entry()]
  def parse(message) do
    for [_, size, mtime, path] <- Regex.scan(~r/^created: (\d+) (-?\d+) (.+)$/m, message),
        do: %{path: path, size: String.to_integer(size), mtime: String.to_integer(mtime)}
  end

  @doc "The files undo of `steps` removes, or why it cannot."
  @spec plan(Path.t(), [map()]) :: {:ok, [Path.t()]} | {:error, {:created_changed, map(), Path.t()}}
  def plan(cwd, steps) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
      case Enum.find(step.created, &changed?(cwd, &1)) do
        nil -> {:cont, {:ok, acc ++ Enum.map(step.created, &Path.join(cwd, &1.path))}}
        entry -> {:halt, {:error, {:created_changed, Map.take(step, [:id, :label]), entry.path}}}
      end
    end)
  end

  defp changed?(cwd, entry) do
    case File.stat(Path.join(cwd, entry.path), time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} -> {size, mtime} != {entry.size, entry.mtime}
      {:error, _} -> false
    end
  end

  @doc "Removes the planned files."
  @spec remove([Path.t()]) :: :ok
  def remove(paths), do: Enum.each(paths, &File.rm/1)
end
