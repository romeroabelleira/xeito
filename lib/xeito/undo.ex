defmodule Xeito.Undo do
  @moduledoc """
  Undo and redo for what the agent changed in a workspace, step by step
  (`docs/implementation-plan.md`, undo stage 1).

  `step/5` wraps one effect that may change files (`write`, `edit`, `bash`): the workspace is
  snapshotted before and after it into a private git store, `.xeito/undo.git`, with its own
  index. The project's own git (HEAD, index, stash) is never touched, and a workspace without
  git works the same. A step that changed something is pushed on its session's stack (a ref
  in the store). `undo/3` reverts a session's last n steps, newest first, and `redo/3` puts
  them back, oldest first; a new step clears what could be redone.

  Only the agent's own changes are reverted: each step's change is applied in reverse to the
  workspace as it is now, so what the user changed since stays. When the user changed the
  same lines, the undo is refused and nothing changes.

  Not captured, so not undone: files the project ignores, the protected directories (`.git`,
  `.xeito`, `deps`, `_build`, `node_modules`), anything outside the workspace, and any
  workspace with more than 20,000 files (the step then runs without undo). Steps are
  serialized per workspace while they run.
  """

  @max_files 20_000
  @ident [
    {"GIT_AUTHOR_NAME", "xeito"},
    {"GIT_AUTHOR_EMAIL", "xeito@localhost"},
    {"GIT_COMMITTER_NAME", "xeito"},
    {"GIT_COMMITTER_EMAIL", "xeito@localhost"}
  ]

  # Git's own variables, set for commands run inside a git hook, would put the store's index,
  # objects or refs elsewhere (the project's index, for one): they are cleared.
  @inherited Enum.map(~w(GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR), &{&1, nil})

  @type step :: %{id: String.t(), label: String.t()}

  @doc """
  Runs `fun` (one agent step, effect `id`) and returns its result. If it changed the
  workspace, the change is recorded as a step of the effect's session, described by `label`.
  Option: `:max_files` (default 20,000).
  """
  @spec step(Path.t(), String.t(), String.t(), (-> result), keyword()) :: result when result: term()
  def step(cwd, id, label, fun, opts \\ []), do: locked(cwd, fn -> snapshotted(cwd, id, label, fun, opts) end)

  @doc "A session's steps that can be undone, newest first."
  @spec steps(Path.t(), String.t()) :: [step()]
  def steps(cwd, session), do: cwd |> stack(undo_ref(session)) |> Enum.map(&Map.take(&1, [:id, :label]))

  @doc """
  Reverts a session's last `n` steps, newest first, and returns them. Errors:
  `:nothing_to_undo`, `{:only, count}`, `{:conflict, step}` (the user changed the same lines
  since), `:unavailable` (no snapshot). On an error, nothing changes.
  """
  @spec undo(Path.t(), String.t(), pos_integer()) :: {:ok, [step()]} | {:error, term()}
  def undo(cwd, session, n), do: locked(cwd, fn -> transfer(cwd, {undo_ref(session), redo_ref(session)}, n, :undo) end)

  @doc "Re-applies the last `n` undone steps of a session, oldest first; like `undo/3` otherwise."
  @spec redo(Path.t(), String.t(), pos_integer()) :: {:ok, [step()]} | {:error, term()}
  def redo(cwd, session, n), do: locked(cwd, fn -> transfer(cwd, {redo_ref(session), undo_ref(session)}, n, :redo) end)

  defp locked(cwd, fun), do: :global.trans({{__MODULE__, cwd}, self()}, fun)

  # --- snapshots ---

  defp snapshot(cwd, opts) do
    with true <- File.dir?(cwd),
         :ok <- init(cwd),
         true <- small?(cwd, opts),
         {_, 0} <- git(cwd, ~w(add -A)),
         {tree, 0} <- git(cwd, ~w(write-tree)) do
      {:ok, String.trim(tree)}
    else
      _ -> :error
    end
  end

  defp init(cwd), do: if(File.dir?(store(cwd)), do: :ok, else: create(cwd))

  defp create(cwd) do
    # `.xeito` is the daemon's own; the project's git must not see it, even before a log exists.
    dot_xeito = Path.dirname(store(cwd))
    File.mkdir_p!(dot_xeito)
    if !File.exists?(Path.join(dot_xeito, ".gitignore")), do: File.write!(Path.join(dot_xeito, ".gitignore"), "*\n")
    {_, 0} = git(cwd, ~w(init))

    for {key, value} <- [{"gc.auto", "0"}, {"core.autocrlf", "false"}, {"advice.addEmbeddedRepo", "false"}],
        do: {_, 0} = git(cwd, ["config", key, value])

    excluded = Enum.map_join(Xeito.Tools.protected_dirs(), &"/#{&1}/\n")
    File.write!(Path.join([store(cwd), "info", "exclude"]), excluded)
  end

  defp small?(cwd, opts) do
    {files, 0} = git(cwd, ~w(ls-files --cached --others --exclude-standard -z))
    length(:binary.matches(files, <<0>>)) <= Keyword.get(opts, :max_files, @max_files)
  end

  defp snapshotted(cwd, id, label, fun, opts) do
    case snapshot(cwd, opts) do
      {:ok, before} ->
        result = fun.()
        recorded(cwd, id, label, before, opts)
        result

      :error ->
        fun.()
    end
  end

  defp recorded(cwd, id, label, before, opts) do
    with {:ok, after_tree} <- snapshot(cwd, opts), do: record(cwd, id, label, before, after_tree)
  end

  defp record(_cwd, _id, _label, tree, tree), do: :unchanged

  defp record(cwd, id, label, before, after_tree) do
    session = id |> String.split("/") |> hd()
    push(cwd, undo_ref(session), %{id: id, label: label, before: before, after: after_tree})
    git(cwd, ["update-ref", "-d", redo_ref(session)])
  end

  # --- stacks: a chain of commits per session, each one step ---

  defp undo_ref(session), do: "refs/xeito/undo/#{session}"
  defp redo_ref(session), do: "refs/xeito/redo/#{session}"

  defp push(cwd, ref, step) do
    parent =
      case git(cwd, ["rev-parse", "--verify", "-q", ref]) do
        {sha, 0} -> ["-p", String.trim(sha)]
        _ -> []
      end

    message = "#{step.label}\n\nid: #{step.id}\nbefore: #{step.before}"
    {commit, 0} = git(cwd, ["commit-tree", step.after, "-m", message | parent])
    {_, 0} = git(cwd, ["update-ref", ref, String.trim(commit)])
  end

  defp stack(cwd, ref) do
    with true <- File.dir?(store(cwd)),
         {log, 0} <- git(cwd, ["log", "--format=%H%x1f%T%x1f%B%x1e", ref, "--"]) do
      log |> String.split("\x1e", trim: true) |> Enum.map(&parse/1) |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  defp parse(record) do
    with [commit, after_tree, body] <- String.split(String.trim(record), "\x1f"),
         [label, meta] <- String.split(body, "\n\n", parts: 2),
         %{"id" => id, "before" => before} <- Regex.named_captures(~r/id: (?<id>\S+)\nbefore: (?<before>\S+)/, meta) do
      %{commit: commit, id: id, label: label, before: before, after: after_tree}
    else
      _ -> nil
    end
  end

  # --- undo and redo ---

  defp transfer(cwd, {from, to}, n, direction) do
    stack = stack(cwd, from)
    moved = Enum.take(stack, n)

    with :ok <- enough(stack, n, direction),
         {:ok, current} <- current(cwd),
         {:ok, target} <- target(cwd, current, moved, direction),
         :ok <- apply_patch(cwd, current, target) do
      Enum.each(moved, &push(cwd, to, &1))
      pop(cwd, from, Enum.at(stack, n))
      {:ok, Enum.map(moved, &Map.take(&1, [:id, :label]))}
    end
  end

  defp enough([], _n, :undo), do: {:error, :nothing_to_undo}
  defp enough([], _n, :redo), do: {:error, :nothing_to_redo}
  defp enough(stack, n, _direction) when length(stack) < n, do: {:error, {:only, length(stack)}}
  defp enough(_stack, _n, _direction), do: :ok

  defp current(cwd), do: with(:error <- snapshot(cwd, []), do: {:error, :unavailable})

  # The workspace with the steps' changes reverted (or re-applied), built in a scratch index so
  # that a conflict leaves the workspace as it was.
  defp target(cwd, current, steps, direction) do
    index = [{"GIT_INDEX_FILE", Path.join(store(cwd), "index.undo")}]
    {_, 0} = git(cwd, ["read-tree", current], index)

    steps
    |> Enum.reduce_while(:ok, fn step, :ok ->
      {from, to} = if direction == :undo, do: {step.after, step.before}, else: {step.before, step.after}

      case patch(cwd, from, to, ["apply", "--cached"], index) do
        :ok -> {:cont, :ok}
        :error -> {:halt, {:error, {:conflict, Map.take(step, [:id, :label])}}}
      end
    end)
    |> then(fn result ->
      with :ok <- result, {tree, 0} <- git(cwd, ["write-tree"], index), do: {:ok, String.trim(tree)}
    end)
  end

  defp apply_patch(_cwd, tree, tree), do: :ok

  defp apply_patch(cwd, current, target) do
    with :error <- patch(cwd, current, target, ["apply"], []), do: {:error, :changed}
  end

  # Applies the change from tree `from` to tree `to` with `git apply` (`command`).
  defp patch(cwd, from, to, command, env) do
    {diff, 0} = git(cwd, ["diff", "--binary", from, to])
    file = Path.join(store(cwd), "undo.patch")
    File.write!(file, diff)

    case git(cwd, command ++ ["--whitespace=nowarn", file], env) do
      {_, 0} -> :ok
      _ -> :error
    end
  end

  defp pop(cwd, ref, nil), do: git(cwd, ["update-ref", "-d", ref])
  defp pop(cwd, ref, next), do: git(cwd, ["update-ref", ref, next.commit])

  defp store(cwd), do: Path.join([cwd, ".xeito", "undo.git"])

  # Only stdout is read (trees, commits, diffs); warnings on stderr are dropped, the exit
  # status tells success.
  defp git(cwd, args, env \\ []) do
    inherited = Enum.reject(@inherited, fn {name, nil} -> List.keymember?(env, name, 0) end)
    env = [{"GIT_DIR", store(cwd)}, {"GIT_WORK_TREE", cwd} | @ident] ++ inherited ++ env
    System.cmd("sh", ["-c", ~s(exec git "$@" 2>/dev/null), "git" | args], cd: cwd, env: env)
  end
end
