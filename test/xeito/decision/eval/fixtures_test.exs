defmodule Xeito.Decision.Eval.FixturesTest do
  use ExUnit.Case, async: true

  alias Xeito.Decision.Eval.Fixtures

  @moduletag :tmp_dir

  defp git(ws, args), do: ws |> then(&System.cmd("git", args, cd: &1, stderr_to_stdout: true)) |> elem(0)

  test "project: a git repository with tracked, untracked, ignored, oversized and secret files", %{tmp_dir: root} do
    ws = Fixtures.build("project", root)

    assert ws |> git(~w(ls-files)) |> String.split("\n", trim: true) |> Enum.sort() ==
             ~w(.gitignore README.md lib/a.ex lib/b.ex notes.txt)

    assert ws |> git(~w(branch --format=%\(refname:short\))) |> String.split("\n", trim: true) |> Enum.sort() ==
             ~w(feature main)

    assert File.read!(Path.join(ws, "draft.txt")) =~ "draft"
    assert git(ws, ~w(check-ignore build/cache/x debug.log)) == "build/cache/x\ndebug.log\n"
    assert File.stat!(Path.join(ws, "big.bin")).size > Xeito.Undo.max_file_bytes()
    assert File.read!(Path.join(ws, ".env")) =~ "SECRET"
    assert {:ok, target} = File.read_link(Path.join(ws, "out_dir"))
    assert Path.expand(target, ws) == Path.join(Path.dirname(ws), "outside")
    assert File.exists?(Path.join([ws, "out_dir", "f.txt"]))
  end

  test "plain: the same files, without git", %{tmp_dir: root} do
    ws = Fixtures.build("plain", root)
    refute File.exists?(Path.join(ws, ".git"))
    assert File.exists?(Path.join(ws, "lib/a.ex"))
    assert File.exists?(Path.join(ws, "build/cache/x"))
  end

  test "each build is fresh, in its own directory; an unknown name is an error", %{tmp_dir: root} do
    a = Fixtures.build("project", Path.join(root, "a"))
    File.rm!(Path.join(a, "notes.txt"))
    b = Fixtures.build("project", Path.join(root, "b"))
    assert File.exists?(Path.join(b, "notes.txt"))
    assert Fixtures.names() == ~w(plain project)
    assert_raise ArgumentError, ~r/unknown fixture "nope"/, fn -> Fixtures.build("nope", root) end
  end
end
