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

  Files the project ignores are captured when small (`.env`, `*.log`), so deleting one can be
  undone. Not captured, so not undone: directories the project ignores (`_build/`, `.venv/`,
  what a build or install recreates), the protected directories (`.git`,
  `.xeito`, `deps`, `_build`, `node_modules`), files over 5 MB (a step names the ones it
  changed), anything outside the workspace, and any workspace with more than 20,000 files (the
  step then runs without undo). Steps are serialized per workspace while they run.

  Retention: a session keeps at least its last 200 steps; past 400, the oldest are dropped
  down to 200. `forget/2` drops a session's steps (`mix xeito.log prune` calls it for the
  sessions it deletes), and `gc/1` frees the file versions no step holds any more (run when
  the workspace's log closes after being idle).
  """

  alias Xeito.Undo.Branch
  alias Xeito.Undo.Outside
  alias Xeito.Undo.Store

  @max_files 20_000
  @max_steps 200
  @max_file_bytes 5_000_000
  @type step :: %{id: String.t(), label: String.t(), skipped: [Path.t()], git: Branch.change()}

  @doc """
  Runs `fun` (one agent step, effect `id`) and returns its result. If it changed the
  workspace, the change is recorded as a step of the effect's session, described by `label`.
  Options: `:max_files` (default 20,000), `:max_file_bytes` (default 5 MB), `:max_steps`
  (default 200).
  """
  @spec step(Path.t(), String.t(), String.t(), (-> result), keyword()) :: result when result: term()
  def step(cwd, id, label, fun, opts \\ []), do: locked(cwd, fn -> snapshotted(cwd, id, label, fun, opts) end)

  @doc "A session's steps that can be undone, newest first."
  @spec steps(Path.t(), String.t()) :: [step()]
  def steps(cwd, session), do: cwd |> stack(undo_ref(session)) |> Enum.map(&public/1)

  @doc """
  Reverts a session's last `n` steps, newest first, and returns them. Errors:
  `:nothing_to_undo`, `{:only, count}`, `{:conflict, step}` (the user changed the same lines
  since), `:unavailable` (no snapshot). On an error, nothing changes. Options as for `step/5`.
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

  defp max_bytes(opts), do: Keyword.get(opts, :max_file_bytes, @max_file_bytes)

  defp locked(cwd, fun), do: :global.trans({{__MODULE__, cwd}, self()}, fun)

  defp public(step),
    do: step |> Map.take([:id, :label, :skipped, :git]) |> Map.put(:outside, Enum.map(step.outside, & &1.path))

  # --- snapshots ---

  # The workspace's tree, and the files left out for their size (with their size and mtime,
  # to tell which ones a step changed).
  defp snapshot(cwd, opts) do
    with true <- File.dir?(cwd), :ok <- init(cwd), {:ok, ignored} <- within_limit(cwd, opts) do
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

  # The ignored files to capture, if the workspace is within the file limit.
  defp within_limit(cwd, opts) do
    {files, 0} = git(cwd, ~w(ls-files --cached --others --exclude-standard -z))
    ignored = ignored_files(cwd, opts)

    if length(:binary.matches(files, <<0>>)) + length(ignored) <= Keyword.get(opts, :max_files, @max_files),
      do: {:ok, ignored},
      else: :error
  end

  # Files the project ignores (`.env`, `*.log`) are captured when small; ignored directories
  # (`_build/`, `.venv/`, `target/`) are not: they hold what a build or install recreates.
  defp ignored_files(cwd, opts) do
    max = max_bytes(opts)
    {entries, 0} = git(cwd, ~w(ls-files -z --others --ignored --exclude-standard --directory))

    for entry <- String.split(entries, <<0>>, trim: true),
        not String.ends_with?(entry, "/"),
        {:ok, %File.Stat{type: :regular, size: size}} <- [File.stat(Path.join(cwd, entry))],
        size <= max,
        do: entry
  end

  defp snapshotted(cwd, id, label, fun, opts) do
    case snapshot(cwd, opts) do
      {:ok, before, big} ->
        state = {before, big, Branch.head(cwd), Outside.capture(cwd, Keyword.get(opts, :outside, []), max_bytes(opts))}
        result = fun.()
        recorded(cwd, {id, label}, state, opts)
        result

      :error ->
        fun.()
    end
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

  # Past twice the limit, the chain is rebuilt from its newest `max` steps: the cost of the
  # rebuild is spread over the steps between two of them.
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

  # A step with backups outside the workspace commits a tree holding them too (`Outside.tree/3`).
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

  # The workspace, and the branch when the steps committed, with the steps reverted (or
  # re-applied). Everything is checked first: on an error, nothing has changed.
  defp revert(cwd, steps, direction, opts) do
    with {:ok, branch, outside} <- plans(cwd, steps, direction),
         {:ok, current} <- current(cwd, opts),
         {:ok, target} <- target(cwd, current, steps, direction),
         :ok <- apply_patch(cwd, current, target),
         :ok <- Outside.restore(cwd, outside),
         do: Branch.move(cwd, branch)
  end

  # What else changes besides the workspace, checked before anything does.
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

  defp apply_patch(cwd, current, target) do
    with :error <- patch(cwd, current, target, ["apply"], []), do: {:error, :changed}
  end

  # Applies the change from tree `from` to tree `to` with `git apply` (`command`). No change (a
  # step that only committed) applies trivially: git refuses an empty patch.
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
