defmodule Xeito.Undo.Outside do
  @moduledoc """
  Files outside the workspace that a step names (`Xeito.Undo.step/5`'s `:outside`, from
  `Xeito.Decisions.Risk.written_paths/1`). Their content before and after the step is kept in
  the store as blobs, held by the step's commit (`tree/3`), so they live as long as the step.
  Undo puts the earlier content back, or removes a file the step created, and redo the later
  one, but only while the file is still as it was left: otherwise nothing changes.

  Only regular files up to the size limit, or absent ones, are backed up; a directory or a
  larger file is not.
  """

  alias Xeito.Undo.Store

  @type entry :: %{path: Path.t(), before: String.t() | nil, after: String.t() | nil}

  @doc "Each path's content now, as a stored blob: `%{path => blob | nil (absent) | :skip}`."
  @spec capture(Path.t(), [Path.t()], non_neg_integer()) :: %{Path.t() => String.t() | nil | :skip}
  def capture(cwd, paths, max_bytes), do: Map.new(paths, &{&1, blob(cwd, &1, max_bytes, ["-w"])})

  defp blob(cwd, path, max_bytes, write) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes ->
        {sha, 0} = Store.git(cwd, ["hash-object", "--no-filters" | write] ++ ["--", path])
        String.trim(sha)

      {:error, :enoent} ->
        nil

      _ ->
        :skip
    end
  end

  @doc "The named paths whose content changed between two captures."
  @spec changes(map(), map()) :: [entry()]
  def changes(before, after_capture) do
    for {path, was} <- before,
        now <- [Map.get(after_capture, path)],
        was != now and :skip not in [was, now],
        do: %{path: path, before: was, after: now}
  end

  @doc """
  A tree holding the workspace tree (`workspace`) and the backups (`outside`), so that the step's
  commit keeps the blobs from garbage collection.
  """
  @spec tree(Path.t(), String.t(), [entry()]) :: String.t()
  def tree(cwd, workspace, entries) do
    blobs =
      for {entry, i} <- Enum.with_index(entries),
          {side, sha} <- [before: entry.before, after: entry.after],
          sha != nil,
          do: "100644 blob #{sha}\t#{i}-#{side}"

    Store.mktree(cwd, ["040000 tree #{workspace}\tworkspace", "040000 tree #{Store.mktree(cwd, blobs)}\toutside"])
  end

  @doc "A step's backups as lines of its commit message, and back."
  @spec lines([entry()]) :: [String.t()]
  def lines(entries), do: Enum.map(entries, &"outside: #{&1.before || "-"} #{&1.after || "-"} #{&1.path}")

  @spec parse(String.t()) :: [entry()]
  def parse(message) do
    for [_, was, now, path] <- Regex.scan(~r/^outside: (\S+) (\S+) (.+)$/m, message),
        do: %{path: path, before: absent(was), after: absent(now)}
  end

  defp absent("-"), do: nil
  defp absent(sha), do: sha

  @doc """
  What undo (or redo) of `steps`, in the order they are taken, puts in each path:
  `{:ok, [{path, blob | nil}]}`, or `{:error, {:outside_changed, step, path}}` when a file is
  no longer as the steps left it.
  """
  @spec plan(Path.t(), [map()], :undo | :redo) :: {:ok, [{Path.t(), String.t() | nil}]} | {:error, term()}
  def plan(cwd, steps, direction) do
    for_result = for(step <- steps, entry <- step.outside, do: {step, entry})

    for_result
    |> Enum.group_by(fn {_step, entry} -> entry.path end)
    |> Enum.reduce_while({:ok, []}, fn {path, entries}, {:ok, acc} ->
      case restore_plan(cwd, path, entries, direction) do
        {:ok, put} -> {:cont, {:ok, [put | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  # The newest change in the order taken must still be on disk; the oldest one says what to put.
  defp restore_plan(cwd, path, [{step, first} | _] = entries, direction) do
    {_, last} = List.last(entries)
    {expect, put} = if direction == :undo, do: {first.after, last.before}, else: {first.before, last.after}

    if blob(cwd, path, :infinity, []) == expect,
      do: {:ok, {path, put}},
      else: {:error, {:outside_changed, Map.take(step, [:id, :label]), path}}
  end

  @doc "Puts each path's planned content (or removes it)."
  @spec restore(Path.t(), [{Path.t(), String.t() | nil}]) :: :ok
  def restore(cwd, plan) do
    Enum.each(plan, fn
      {path, nil} ->
        File.rm(path)

      {path, sha} ->
        {content, 0} = Store.git(cwd, ["cat-file", "blob", sha])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
    end)
  end
end
