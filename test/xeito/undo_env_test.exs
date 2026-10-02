defmodule Xeito.UndoEnvTest do
  # Not async: it sets git's environment for the whole VM, as a git hook does for its commands.
  use ExUnit.Case, async: false

  alias Xeito.Undo

  setup do
    ws = Path.join(System.tmp_dir!(), "xeito-undo-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)
    %{ws: ws}
  end

  test "a step taken inside a git hook (git's variables set) is undone outside it", %{ws: ws} do
    vars = %{
      "GIT_INDEX_FILE" => Path.join(ws, "other-index"),
      "GIT_OBJECT_DIRECTORY" => Path.join(ws, "other-objects"),
      "GIT_COMMON_DIR" => Path.join(ws, "other-common")
    }

    for {name, value} <- vars, do: System.put_env(name, value)
    on_exit(fn -> Enum.each(Map.keys(vars), &System.delete_env/1) end)
    Undo.step(ws, "ses-h/t1/e1", "write a.txt", fn -> File.write!(Path.join(ws, "a.txt"), "a\n") end)
    Enum.each(Map.keys(vars), &System.delete_env/1)

    assert [%{label: "write a.txt"}] = Undo.steps(ws, "ses-h")
    assert {:ok, _} = Undo.undo(ws, "ses-h", 1)
    refute File.exists?(Path.join(ws, "a.txt"))
    for path <- ~w(other-index other-objects other-common), do: refute(File.exists?(Path.join(ws, path)))
  end
end
