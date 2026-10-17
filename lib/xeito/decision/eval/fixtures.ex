defmodule Xeito.Decision.Eval.Fixtures do
  @moduledoc """
  Named workspaces that labelled examples run in, for decisions that read the workspace (`Risk`'s `cwd`).

  `build/2` makes a fresh copy of a fixture under a root directory and returns the workspace's
  path; a sibling `outside/` holds what the workspace's symlink points to. The fixtures:

  - `project`: a git repository on `main`, with a `feature` branch. Tracked: `.gitignore`,
    `README.md`, `notes.txt`, `lib/a.ex`, `lib/b.ex`. Untracked: `draft.txt`, `.env`, and
    `big.bin`, over `Xeito.Undo.max_file_bytes/0`. Ignored: `build/` (with `build/out.bin` and
    `build/cache/x`) and `debug.log`. `out_dir` links to `../outside`, which holds `f.txt`.
  - `plain`: the same files and link, without git.
  """

  @files %{
    ".gitignore" => "build/\n*.log\n",
    "README.md" => "# Fixture\n",
    "notes.txt" => "notes\n",
    "lib/a.ex" => "defmodule A, do: def(a, do: 1)\n",
    "lib/b.ex" => "defmodule B, do: def(b, do: 2)\n",
    "draft.txt" => "a draft\n",
    ".env" => "SECRET=not-a-real-secret\n",
    "build/out.bin" => "built\n",
    "build/cache/x" => "cached\n",
    "debug.log" => "log line\n"
  }
  @tracked ~w(.gitignore README.md notes.txt lib/a.ex lib/b.ex)

  @doc "The fixtures' names."
  @spec names() :: [String.t()]
  def names, do: ~w(plain project)

  @doc "Builds fixture `name` fresh under `root` and returns the workspace's path."
  @spec build(String.t(), Path.t()) :: Path.t()
  def build(name, root) when name in ["plain", "project"] do
    dir = Path.join(root, name)
    File.rm_rf!(dir)
    ws = Path.join(dir, "ws")
    outside = Path.join(dir, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "f.txt"), "outside\n")

    for {path, text} <- @files, do: write(ws, path, text)
    write(ws, "big.bin", :binary.copy("b", Xeito.Undo.max_file_bytes() + 1))
    File.ln_s!("../outside", Path.join(ws, "out_dir"))
    if name == "project", do: repository(ws)
    ws
  end

  def build(name, _root),
    do: raise(ArgumentError, "unknown fixture #{inspect(name)}; the fixtures are #{Enum.join(names(), ", ")}")

  defp write(ws, path, text) do
    full = Path.join(ws, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, text)
  end

  @identity ~w(-c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false)

  defp repository(ws) do
    git(ws, ~w(init -q -b main))
    git(ws, ["add", "--" | @tracked])
    git(ws, @identity ++ ~w(commit -q -m fixture))
    git(ws, ~w(branch feature))
  end

  defp git(ws, args), do: {_, 0} = System.cmd("git", args, cd: ws, stderr_to_stdout: true)
end
