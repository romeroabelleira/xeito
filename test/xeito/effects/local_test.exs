defmodule Xeito.Effects.LocalTest do
  use ExUnit.Case, async: true

  alias Xeito.Effect
  alias Xeito.Effects.Local

  setup do
    dir = Path.join(System.tmp_dir!(), "xeito-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{ws: dir}
  end

  test "bash runs in the workspace and reports the exit status", %{ws: ws} do
    assert %{exit_status: 0, output: output} = Local.run(Effect.bash("pwd", cwd: ws), [])
    assert String.trim(output) == Path.expand(ws)
    assert %{exit_status: 3} = Local.run(Effect.bash("exit 3", cwd: ws), [])
  end

  test "bash times out", %{ws: ws} do
    assert %{exit_status: 124} = Local.run(Effect.bash("sleep 5", cwd: ws, timeout: 50), [])
  end

  test "write and read stay inside the workspace", %{ws: ws} do
    assert %{ok: true} = Local.run(Effect.write("sub/a.txt", "hello", cwd: ws), [])
    assert %{ok: true, content: "hello"} = Local.run(Effect.read("sub/a.txt", cwd: ws), [])

    assert %{ok: false, error: :outside_workspace} =
             Local.run(Effect.read("../../etc/passwd", cwd: ws), [])

    assert %{ok: false, error: :outside_workspace} =
             Local.run(Effect.write("/tmp/x", "no", cwd: ws), [])
  end

  test "decide is stubbed until P2" do
    assert %{value: :abstain} = Local.run(Effect.decide(:triage), [])
    assert %{value: :code_bug} = Local.run(Effect.decide(:triage), decide: fn _ -> :code_bug end)
  end
end
