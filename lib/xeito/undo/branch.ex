defmodule Xeito.Undo.Branch do
  @moduledoc """
  The project's own git, as far as undo needs it (`Xeito.Undo`): where HEAD is before and after
  a step, and moving a branch back over the commits a step made, or forward again for redo.

  Only new commits on the branch HEAD is on can be undone, and only while the branch is still
  where the steps left it and none of the commits has been pushed (is on a remote-tracking
  branch). Any other move of HEAD (a checkout, reset or rebase) is a step undo refuses.
  """

  # Git's own variables (set inside a git hook) would point at another repository or index.
  @clear Enum.map(~w(GIT_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR), &{&1, nil})

  @type head :: {String.t() | nil, String.t()} | nil
  @type change :: nil | :moved | %{ref: String.t(), from: String.t(), to: String.t()}

  @doc "Where HEAD is: `{branch ref or nil when detached, commit}`, or nil outside a repository or before its first commit."
  @spec head(Path.t()) :: head()
  def head(cwd) do
    case git(cwd, ~w(rev-parse HEAD)) do
      {sha, 0} -> {symbolic(cwd), String.trim(sha)}
      _ -> nil
    end
  end

  defp symbolic(cwd) do
    case git(cwd, ~w(symbolic-ref HEAD)) do
      {ref, 0} -> String.trim(ref)
      _ -> nil
    end
  end

  @doc "What a step did to HEAD: nothing, new commits on its branch, or another move (`:moved`)."
  @spec change(Path.t(), head(), head()) :: change()
  def change(_cwd, head, head), do: nil

  def change(cwd, {ref, from}, {ref, to}) when is_binary(ref),
    do: if(ancestor?(cwd, from, to), do: %{ref: ref, from: from, to: to}, else: :moved)

  def change(_cwd, _before, _after), do: :moved

  defp ancestor?(cwd, commit, descendant),
    do: match?({_, 0}, git(cwd, ["merge-base", "--is-ancestor", commit, descendant]))

  @doc """
  The checked branch move that undoes (`:undo`) or redoes the commits of `steps`, in the order
  they are taken: `{:ok, nil}` when they made none, or `{:ok, move}`. Errors name the step:
  `{:git, step, :moved}`, `{:git, step, :branch_moved}`, `{:git, step, {:pushed, commit}}`.
  """
  @spec plan(Path.t(), [map()], :undo | :redo) :: {:ok, map() | nil} | {:error, term()}
  def plan(cwd, steps, direction) do
    case Enum.find(steps, &(&1.git == :moved)) do
      nil -> steps |> Enum.filter(& &1.git) |> plan_move(cwd, direction)
      step -> refuse(step, :moved)
    end
  end

  defp plan_move([], _cwd, _direction), do: {:ok, nil}

  defp plan_move([first | _] = steps, cwd, direction) do
    last = List.last(steps)
    {expect, set} = if direction == :undo, do: {first.git.to, last.git.from}, else: {first.git.from, last.git.to}
    move = %{ref: first.git.ref, expect: expect, set: set}

    with :ok <- where_left(cwd, move, first), :ok <- unpushed(cwd, move, last, direction), do: {:ok, move}
  end

  # HEAD is still on the branch, and the branch where the steps left it.
  defp where_left(cwd, move, step),
    do: if(head(cwd) == {move.ref, move.expect}, do: :ok, else: refuse(step, :branch_moved))

  defp unpushed(_cwd, _move, _step, :redo), do: :ok

  defp unpushed(cwd, move, step, :undo) do
    {commits, 0} = git(cwd, ["rev-list", "--reverse", "#{move.set}..#{move.expect}"])
    oldest = commits |> String.split() |> hd()
    {remotes, 0} = git(cwd, ["for-each-ref", "--contains", oldest, "refs/remotes"])
    if remotes == "", do: :ok, else: refuse(step, {:pushed, oldest})
  end

  defp refuse(step, reason), do: {:error, {:git, Map.take(step, [:id, :label]), reason}}

  @doc """
  Moves the branch (only if it is still where the plan found it), and resets the project's index
  to the new position for the files the commits touched: their changes stay in the working tree.
  """
  @spec move(Path.t(), map() | nil) :: :ok | {:error, :changed}
  def move(_cwd, nil), do: :ok

  def move(cwd, move) do
    {paths, 0} = git(cwd, ["diff", "--name-only", "-z", move.set, move.expect])

    case git(cwd, ["update-ref", move.ref, move.set, move.expect]) do
      {_, 0} ->
        reset_index(cwd, move.set, String.split(paths, <<0>>, trim: true))
        :ok

      _ ->
        {:error, :changed}
    end
  end

  # Without paths, `git reset` would reset the whole index: the user's staged changes too.
  defp reset_index(_cwd, _commit, []), do: :ok
  defp reset_index(cwd, commit, paths), do: git(cwd, ["--literal-pathspecs", "reset", "-q", commit, "--" | paths])

  defp git(cwd, args), do: System.cmd("sh", ["-c", ~s(exec git "$@" 2>/dev/null), "git" | args], cd: cwd, env: @clear)
end
