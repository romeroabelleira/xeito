defmodule Xeito.RiskOracle do
  @moduledoc """
  Runs a shell command in fresh fixture workspaces and observes what undo and a second run do: the ground truth for `Risk`.

  `observe/3` builds the fixture twice (`Xeito.Decision.Eval.Fixtures`) and runs the command
  through `Xeito.Effects.Local`, as a run does, so the same undo step and backup of outside files
  apply. It returns:

  - `changed`: what the run changed, as `ws/<path>`, `outside/<path>` or `git:<ref>`;
  - `undoable`: `nil` when nothing changed, else whether `Xeito.Undo.undo/3` restored every
    file, link and ref;
  - `repeatable`: whether a second run left the state of the first, with the same exit status;
  - `outside`: whether anything outside the workspace changed.

  A state is the workspace's and `outside/`'s files (mode and content) and symlinks (target), and
  the project's git refs and HEAD. Not in it: `.git`'s other files, the undo store, empty
  directories (git, and so undo, does not track them) and times. Commands run with no network
  cut: examples must not reach the network.
  """

  alias Xeito.Decision.Eval.Fixtures
  alias Xeito.Effect
  alias Xeito.Effects.Local

  @type observation :: %{changed: [String.t()], undoable: boolean() | nil, repeatable: boolean(), outside: boolean()}

  @doc "What running `command` in fixture `fixture` changes, and whether undo and a second run hold."
  @spec observe(String.t(), String.t(), Path.t()) :: observation()
  def observe(command, fixture, root) do
    ws = Fixtures.build(fixture, Path.join(root, "undo"))
    before = state(ws)
    run(ws, command, "oracle-undo")
    after_run = state(ws)
    Xeito.Undo.undo(ws, "oracle-undo", 1)
    restored = state(ws)

    twice = Fixtures.build(fixture, Path.join(root, "twice"))
    first = run(twice, command, "oracle-first")
    once = state(twice)
    second = run(twice, command, "oracle-second")

    changed = changed(before, after_run)

    %{
      changed: changed,
      undoable: if(changed == [], do: nil, else: restored == before),
      repeatable: state(twice) == once and first == second,
      outside: Enum.any?(changed, &String.starts_with?(&1, "outside/"))
    }
  end

  defp run(ws, command, session) do
    effect = %{Effect.bash(command, cwd: ws, timeout: 20_000) | id: "#{session}/t1/e1"}
    Local.run(effect, []).exit_status
  end

  defp changed(before, later) do
    keys = MapSet.union(MapSet.new(Map.keys(before)), MapSet.new(Map.keys(later)))
    keys |> Enum.filter(&(before[&1] != later[&1])) |> Enum.sort()
  end

  # Path → what it is, for the workspace, outside/ and the git refs.
  defp state(ws) do
    outside = Path.join(Path.dirname(ws), "outside")

    ws
    |> files("ws")
    |> Map.merge(files(outside, "outside"))
    |> Map.merge(refs(ws))
  end

  defp files(dir, prefix) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&(prefix == "ws" and &1 in [".git", ".xeito"]))
        |> Enum.reduce(%{}, &entry(dir, prefix, &1, &2))

      {:error, _} ->
        %{}
    end
  end

  defp entry(dir, prefix, name, acc) do
    path = Path.join(dir, name)
    key = Path.join(prefix, name)

    case File.lstat!(path) do
      %File.Stat{type: :directory} -> Map.merge(acc, files(path, key))
      %File.Stat{type: :symlink} -> Map.put(acc, key, {:link, File.read_link!(path)})
      %File.Stat{mode: mode} -> Map.put(acc, key, {:file, mode, :crypto.hash(:sha256, File.read!(path))})
    end
  end

  defp refs(ws) do
    if File.dir?(Path.join(ws, ".git")) do
      {out, 0} = System.cmd("git", ["for-each-ref", "--format=%(refname) %(objectname)"], cd: ws)
      {head, _} = System.cmd("git", ["symbolic-ref", "-q", "HEAD"], cd: ws)

      for line <- String.split(out, "\n", trim: true), into: %{"git:HEAD" => String.trim(head)} do
        [ref, sha] = String.split(line, " ")
        {"git:" <> ref, sha}
      end
    else
      %{}
    end
  end
end
