defmodule Xeito.PreloadTest do
  use ExUnit.Case, async: true

  alias Xeito.Preload

  test "load_all/1 loads every module of the given applications, and says how many" do
    {:ok, modules} = :application.get_key(:eex, :modules)
    assert Preload.load_all([:eex]) == length(modules)
    assert Enum.all?(modules, &:code.is_loaded/1)
  end

  test "changed_since/2: the compiled files written after a time, in the given directories" do
    dir = Path.join(System.tmp_dir!(), "xeito-preload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    old = Path.join(dir, "Elixir.Old.beam")
    new = Path.join(dir, "Elixir.New.beam")
    File.write!(old, "")
    File.write!(new, "")
    File.write!(Path.join(dir, "notes.app"), "")
    File.touch!(old, 1_000)
    File.touch!(new, 3_000)

    assert Preload.changed_since([dir], 2_000) == [new]
    assert Preload.changed_since([dir], 4_000) == []
    assert Preload.changed_since([Path.join(dir, "missing")], 0) == []
  end
end
