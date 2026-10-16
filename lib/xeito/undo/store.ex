defmodule Xeito.Undo.Store do
  @moduledoc """
  Runs git against a workspace's undo store, `.xeito/undo.git`, with its own index, apart from the project's git.
  """

  @ident [
    {"GIT_AUTHOR_NAME", "xeito"},
    {"GIT_AUTHOR_EMAIL", "xeito@localhost"},
    {"GIT_COMMITTER_NAME", "xeito"},
    {"GIT_COMMITTER_EMAIL", "xeito@localhost"}
  ]

  # Cleared: set inside a git hook, they would redirect the store to the project's index or objects.
  @inherited Enum.map(~w(GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR), &{&1, nil})

  @doc "The store's directory in a workspace."
  @spec path(Path.t()) :: Path.t()
  def path(cwd), do: Path.join([cwd, ".xeito", "undo.git"])

  @doc """
  Runs git against the store, the workspace as its work tree. Only stdout is read (trees,
  commits, diffs); warnings on stderr are dropped, and the exit status tells success.
  """
  @spec git(Path.t(), [String.t()], [{String.t(), String.t() | nil}]) :: {String.t(), non_neg_integer()}
  def git(cwd, args, env \\ []),
    do: System.cmd("sh", ["-c", ~s(exec git "$@" 2>/dev/null), "git" | args], cd: cwd, env: env(cwd, env))

  @doc "Writes a tree from `git ls-tree` lines (`<mode> <type> <id>\\t<name>`) and returns its id."
  @spec mktree(Path.t(), [String.t()]) :: String.t()
  def mktree(cwd, lines) do
    script = ~s(printf '%s\\n' "$@" | git mktree 2>/dev/null)
    {tree, 0} = System.cmd("sh", ["-c", script, "sh" | lines], cd: cwd, env: env(cwd, []))
    String.trim(tree)
  end

  # The store's own variables, then git's own cleared; `env` overrides either.
  defp env(cwd, env) do
    [{"GIT_DIR", path(cwd)}, {"GIT_WORK_TREE", cwd} | @ident]
    |> Kernel.++(@inherited)
    |> Map.new()
    |> Map.merge(Map.new(env))
    |> Map.to_list()
  end
end
