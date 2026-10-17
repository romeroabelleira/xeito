defmodule Xeito.Undo do
  @moduledoc """
  Undo and redo of the agent's changes to a workspace, step by step, kept in a private git store.

  * `step/5` snapshots the workspace before and after one effect into `.xeito/undo.git`, with
    its own index; the project's git (HEAD, index, stash) is never touched. A step that changed
    something goes on its session's stack; a new step clears the redo stack.
  * `undo/3` reverts the last n steps, newest first; `redo/3` re-applies them, oldest first.
    Each change is applied in reverse to the workspace as it is now, so the user's later edits
    stay; if the user changed the same lines, nothing changes and an error is returned.
  * Captured: tracked files and small ignored files (`.env`). Not captured: ignored directories,
    `Xeito.Tools.protected_dirs/0`, files over `:max_file_bytes`, and workspaces over
    `:max_files` (the step then runs without undo). Outside files only via `:outside`.
  * Undo bookkeeping never fails a step. Steps are serialized per workspace.
  * A session keeps at least `:max_steps` steps (trimmed back past twice that). `forget/2` drops
    a session's steps; `gc/1` frees file versions no step holds.
  """

  alias Xeito.Undo.Branch
  alias Xeito.Undo.Outside
  alias Xeito.Undo.Store

  @max_files 20_000
  @max_steps 200
  @stale_lock_s 10
  @config [{"gc.auto", "0"}, {"core.autocrlf", "false"}, {"advice.addEmbeddedRepo", "false"}]
  @max_file_bytes 5_000_000
  @type step :: %{id: String.t(), label: String.t(), skipped: [Path.t()], git: Branch.change()}

  @doc """
  Runs `fun` (effect `id`) and returns its result, recording any change as a step labelled `label`.
  Options: `:max_files` (20,000), `:max_file_bytes` (5 MB), `:max_steps` (200), `:outside`
  (paths outside the workspace to back up), `:now` (seconds, for telling a stale lock).
  """
  @spec step(Path.t(), String.t(), String.t(), (-> result), keyword()) :: result when result: term()
  def step(cwd, id, label, fun, opts \\ []), do: locked(cwd, fn -> snapshotted(cwd, id, label, fun, opts) end)

  @doc "A session's steps that can be undone, newest first."
  @spec steps(Path.t(), String.t()) :: [step()]
  def steps(cwd, session), do: cwd |> stack(undo_ref(session)) |> Enum.map(&public/1)

  @doc """
  Reverts a session's last `n` steps, newest first, and returns them. On an error nothing
  changes: `:nothing_to_undo`, `{:only, count}`, `{:conflict, step}` (the user changed the same
  lines), `:unavailable` (no snapshot). Options as for `step/5`.
  """
  @spec undo(Path.t(), String.t(), pos_integer(), keyword()) :: {:ok, [step()]} | {:error, term()}
  def undo(cwd, session, n, opts \\ []),
    do: locked(cwd, fn -> transfer(cwd, {undo_ref(session), redo_ref(session)}, n, {:undo, opts}) end)

  @doc "Re-applies the last `n` undone steps of a session, oldest first; like `undo/3` otherwise."
  @spec redo(Path.t(), String.t(), pos_integer(), keyword()) :: {:ok, [step()]} | {:error, term()}
  def redo(cwd, session, n, opts \\ []),
    do: locked(cwd, fn -> transfer(cwd, {redo_ref(session), undo_ref(session)}, n, {:redo, opts}) end)

  @doc "Drops a session's steps, undone ones included."
  @spec forget(Path.t(), String.t()) :: :ok
  def forget(cwd, session) do
    if File.dir?(store(cwd)),
      do: locked(cwd, fn -> Enum.each([undo_ref(session), redo_ref(session)], &git(cwd, ["update-ref", "-d", &1])) end)

    :ok
  end

  @doc "Frees the file versions that no step holds any more, and packs the rest."
  @spec gc(Path.t()) :: :ok
  def gc(cwd) do
    if File.dir?(store(cwd)), do: locked(cwd, fn -> git(cwd, ~w(gc --prune=now)) end)
    :ok
  end

  @doc """
  Whether a snapshot can be taken now and would hold everything under `paths` (relative, may
  not exist yet): no ignored directory and no oversized file under them. `Xeito.Decisions.Risk`
  relies on it to allow writes. Options as for `step/5`.
  """
  @spec covers?(Path.t(), [Path.t()], keyword()) :: boolean()
  def covers?(cwd, paths, opts \\ []) do
    with true <- File.dir?(cwd), :ok <- init(cwd, opts), {:ok, _ignored} <- within_limit(cwd, opts) do
      paths == [] or uncaptured(cwd, paths, opts) == []
    else
      _ -> false
    end
  end

  # A listing git refuses (it does for paths two levels inside an ignored directory) covers nothing.
  defp uncaptured(cwd, paths, opts) do
    with {ignored, 0} <-
           git(cwd, [
             "--literal-pathspecs",
             "ls-files",
             "-z",
             "--others",
             "--ignored",
             "--exclude-standard",
             "--directory",
             "--" | paths
           ]),
         {files, 0} <-
           git(cwd, ["--literal-pathspecs", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--" | paths]) do
      too_big_or_ignored(cwd, ignored, files, opts)
    else
      _ -> paths
    end
  end

  defp too_big_or_ignored(cwd, ignored, files, opts) do
    entries = String.split(ignored, <<0>>, trim: true)
    dirs = Enum.filter(entries, &String.ends_with?(&1, "/"))
    max = max_bytes(opts)
    large = for file <- String.split(files, <<0>>, trim: true) ++ entries, large?(Path.join(cwd, file), max), do: file
    dirs ++ large
  end

  defp large?(path, max), do: match?({:ok, %File.Stat{type: :regular, size: size}} when size > max, File.stat(path))

  defp max_bytes(opts), do: Keyword.get(opts, :max_file_bytes, @max_file_bytes)

  defp locked(cwd, fun), do: :global.trans({{__MODULE__, cwd}, self()}, fun)

  defp public(step),
    do: step |> Map.take([:id, :label, :skipped, :git]) |> Map.put(:outside, Enum.map(step.outside, & &1.path))

  # --- snapshots ---

  # Oversized files are left out but kept with size and mtime, to tell which ones a step changed.
  defp snapshot(cwd, opts) do
    with true <- File.dir?(cwd), :ok <- init(cwd, opts), {:ok, ignored} <- within_limit(cwd, opts) do
      capture(cwd, big_files(cwd, opts), ignored)
    else
      _ -> :error
    end
  end

  defp capture(cwd, big, ignored) do
    with {_, 0} <- git(cwd, ["add", "-A", "--", "." | Enum.map(Map.keys(big), &":(exclude,literal)#{&1}")]),
         {_, 0} <- git(cwd, ["--literal-pathspecs", "add", "--force", "--" | ignored]),
         {_, 0} <- uncapture(cwd, Map.keys(big)),
         {tree, 0} <- git(cwd, ~w(write-tree)) do
      {:ok, String.trim(tree), big}
    else
      _ -> :error
    end
  end

  defp big_files(cwd, opts) do
    max = max_bytes(opts)
    {files, 0} = git(cwd, ~w(ls-files -z --others --modified --exclude-standard))

    for file <- String.split(files, <<0>>, trim: true),
        {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <- [File.stat(Path.join(cwd, file))],
        size > max,
        into: %{},
        do: {file, {size, mtime}}
  end

  # A file captured while it was small is taken out once it is over the limit.
  defp uncapture(cwd, files), do: git(cwd, ["update-index", "--force-remove", "--" | files])

  # A step killed midway can leave a half-built store or a stale index lock: the store is built
  # under a temporary name and renamed, a store git rejects (or a missing one) is rebuilt, and
  # an index lock older than @stale_lock_s is removed.
  defp init(cwd, opts) do
    if match?({_, 0}, git(cwd, ~w(rev-parse))),
      do: clear_stale_lock(cwd, Keyword.get(opts, :now) || System.os_time(:second)),
      else: rebuild(cwd)
  end

  defp rebuild(cwd) do
    File.rm_rf(store(cwd))
    create(cwd)
  end

  defp create(cwd) do
    # The project's git must not see `.xeito`, even before a log exists.
    dot_xeito = Path.dirname(store(cwd))
    File.mkdir_p!(dot_xeito)
    if !File.exists?(Path.join(dot_xeito, ".gitignore")), do: File.write!(Path.join(dot_xeito, ".gitignore"), "*\n")
    new = store(cwd) <> ".new-#{System.unique_integer([:positive])}"

    result = with :ok <- build(cwd, new), do: File.rename(new, store(cwd))
    # Removes a partial build after a failure; a no-op after the rename.
    File.rm_rf(new)
    result
  end

  defp build(cwd, new) do
    env = [{"GIT_DIR", new}]

    with {_, 0} <- git(cwd, ~w(init), env),
         true <- Enum.all?(@config, fn {key, value} -> match?({_, 0}, git(cwd, ["config", key, value], env)) end),
         do: File.write(Path.join([new, "info", "exclude"]), Enum.map_join(Xeito.Tools.protected_dirs(), &"/#{&1}/\n"))
  end

  defp clear_stale_lock(cwd, now) do
    lock = Path.join(store(cwd), "index.lock")

    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(lock, time: :posix),
         true <- now - mtime > @stale_lock_s,
         do: File.rm(lock)

    :ok
  end

  defp within_limit(cwd, opts) do
    {files, 0} = git(cwd, ~w(ls-files --cached --others --exclude-standard -z))
    ignored = ignored_files(cwd, opts)

    if length(:binary.matches(files, <<0>>)) + length(ignored) <= Keyword.get(opts, :max_files, @max_files),
      do: {:ok, ignored},
      else: :error
  end

  # Ignored directories are skipped: they hold what a build or install recreates.
  defp ignored_files(cwd, opts) do
    max = max_bytes(opts)
    {entries, 0} = git(cwd, ~w(ls-files -z --others --ignored --exclude-standard --directory))

    for entry <- String.split(entries, <<0>>, trim: true),
        not String.ends_with?(entry, "/"),
        {:ok, %File.Stat{type: :regular, size: size}} <- [File.stat(Path.join(cwd, entry))],
        size <= max,
        do: entry
  end

  # Bookkeeping never fails the step: if a snapshot or record fails, the step runs without undo.
  defp snapshotted(cwd, id, label, fun, opts) do
    case attempt(fn -> before_step(cwd, opts) end) do
      {:ok, state} ->
        result = fun.()
        attempt(fn -> recorded(cwd, {id, label}, state, opts) end)
        result

      :error ->
        fun.()
    end
  end

  defp before_step(cwd, opts) do
    with {:ok, before, big} <- snapshot(cwd, opts),
         do:
           {:ok, {before, big, Branch.head(cwd), Outside.capture(cwd, Keyword.get(opts, :outside, []), max_bytes(opts))}}
  end

  defp attempt(fun) do
    fun.()
  rescue
    _ -> :error
  end

  defp recorded(cwd, step, {before, big_before, head, outside_before}, opts) do
    with {:ok, after_tree, big_after} <- snapshot(cwd, opts) do
      skipped = for {file, stat} <- big_after, big_before[file] != stat, do: file
      outside = Outside.changes(outside_before, Outside.capture(cwd, Map.keys(outside_before), max_bytes(opts)))

      change = %{
        before: before,
        after: after_tree,
        skipped: Enum.sort(skipped),
        git: Branch.change(cwd, head, Branch.head(cwd)),
        outside: outside
      }

      record(cwd, step, change, opts)
    end
  end

  defp record(_cwd, _step, %{before: tree, after: tree, git: nil, outside: []}, _opts), do: :unchanged

  defp record(cwd, {id, label}, change, opts) do
    session = id |> String.split("/") |> hd()
    push(cwd, undo_ref(session), Map.merge(change, %{id: id, label: label}))
    git(cwd, ["update-ref", "-d", redo_ref(session)])
    trim(cwd, undo_ref(session), Keyword.get(opts, :max_steps, @max_steps))
  end

  # Past twice the limit, the chain is rebuilt from its newest `max` steps (amortised cost).
  defp trim(cwd, ref, max) do
    {count, 0} = git(cwd, ["rev-list", "--count", ref])

    if String.to_integer(String.trim(count)) > 2 * max do
      keep = cwd |> stack(ref) |> Enum.take(max)
      git(cwd, ["update-ref", "-d", ref])
      keep |> Enum.reverse() |> Enum.each(&push(cwd, ref, &1))
    end
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

    lines = Enum.map(step.skipped, &"skipped: #{&1}") ++ git_line(step.git) ++ Outside.lines(step.outside)
    message = Enum.join(["#{step.label}\n\nid: #{step.id}\nbefore: #{step.before}\nafter: #{step.after}" | lines], "\n")

    {commit, 0} = git(cwd, ["commit-tree", commit_tree(cwd, step), "-m", message | parent])
    {_, 0} = git(cwd, ["update-ref", ref, String.trim(commit)])
  end

  defp commit_tree(_cwd, %{outside: [], after: tree}), do: tree
  defp commit_tree(cwd, step), do: Outside.tree(cwd, step.after, step.outside)

  defp git_line(nil), do: []
  defp git_line(:moved), do: ["git: moved"]
  defp git_line(%{ref: ref, from: from, to: to}), do: ["git: #{ref} #{from} #{to}"]

  defp stack(cwd, ref) do
    with true <- File.dir?(store(cwd)),
         {log, 0} <- git(cwd, ["log", "--format=%H%x1f%T%x1f%B%x1e", ref, "--"]) do
      log |> String.split("\x1e", trim: true) |> Enum.map(&parse/1) |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  defp parse(record) do
    with [commit, _tree, body] <- String.split(String.trim(record), "\x1f"),
         [label, meta] <- String.split(body, "\n\n", parts: 2),
         %{"id" => id, "before" => before, "after" => after_tree} <-
           Regex.named_captures(~r/id: (?<id>\S+)\nbefore: (?<before>\S+)\nafter: (?<after>\S+)/, meta) do
      skipped = for [_, file] <- Regex.scan(~r/^skipped: (.+)$/m, meta), do: file
      git = Regex.run(~r/^git: (\S+)(?: (\S+) (\S+))?$/m, meta)

      %{
        commit: commit,
        id: id,
        label: label,
        before: before,
        after: after_tree,
        skipped: skipped,
        git: parse_git(git),
        outside: Outside.parse(meta)
      }
    else
      _ -> nil
    end
  end

  defp parse_git(nil), do: nil
  defp parse_git([_, "moved"]), do: :moved
  defp parse_git([_, ref, from, to]), do: %{ref: ref, from: from, to: to}

  # --- undo and redo ---

  defp transfer(cwd, {from, to}, n, {direction, opts}) do
    stack = stack(cwd, from)
    moved = Enum.take(stack, n)

    with :ok <- enough(stack, n, direction), :ok <- revert(cwd, moved, direction, opts) do
      Enum.each(moved, &push(cwd, to, &1))
      pop(cwd, from, Enum.at(stack, n))
      {:ok, Enum.map(moved, &public/1)}
    end
  end

  # Everything is checked before anything is written: on an error, nothing has changed.
  defp revert(cwd, steps, direction, opts) do
    with {:ok, branch, outside} <- plans(cwd, steps, direction),
         {:ok, current} <- current(cwd, opts),
         {:ok, target} <- target(cwd, current, steps, direction),
         :ok <- apply_patch(cwd, current, target),
         :ok <- Outside.restore(cwd, outside),
         do: Branch.move(cwd, branch)
  end

  defp plans(cwd, steps, direction) do
    with {:ok, branch} <- Branch.plan(cwd, steps, direction),
         {:ok, outside} <- Outside.plan(cwd, steps, direction),
         do: {:ok, branch, outside}
  end

  defp enough([], _n, :undo), do: {:error, :nothing_to_undo}
  defp enough([], _n, :redo), do: {:error, :nothing_to_redo}
  defp enough(stack, n, _direction) when length(stack) < n, do: {:error, {:only, length(stack)}}
  defp enough(_stack, _n, _direction), do: :ok

  defp current(cwd, opts) do
    case snapshot(cwd, opts) do
      {:ok, tree, _big} -> {:ok, tree}
      :error -> {:error, :unavailable}
    end
  end

  # Built in a scratch index, so a conflict leaves the workspace as it was.
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

  defp apply_patch(cwd, current, target) do
    with :error <- patch(cwd, current, target, ["apply"], []), do: {:error, :changed}
  end

  # Equal trees (a step that only committed) apply trivially: git refuses an empty patch.
  defp patch(_cwd, tree, tree, _command, _env), do: :ok

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

  defp store(cwd), do: Store.path(cwd)
  defp git(cwd, args, env \\ []), do: Store.git(cwd, args, env)
end
