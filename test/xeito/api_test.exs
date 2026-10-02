defmodule Xeito.ApiTest do
  use ExUnit.Case, async: true

  alias Xeito.Api
  alias Xeito.Client

  # Socket paths are limited to about 100 bytes, too short for ExUnit's tmp_dir.
  setup do
    dir = Path.join(System.tmp_dir!(), "xa-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp start_api(path, id),
    do: start_supervised({Api, socket: path, name: :"api_#{System.unique_integer([:positive])}"}, id: id)

  test "a second daemon on a socket in use refuses to start, and the first keeps serving", %{dir: dir} do
    path = Path.join(dir, "x.sock")
    {:ok, _} = start_api(path, :first)

    assert {:error, {"a daemon is already listening at " <> ^path, _}} = start_api(path, :second)
    assert {:ok, _client} = Client.connect(path)
  end

  test "a socket file left by a daemon that died is replaced", %{dir: dir} do
    path = Path.join(dir, "x.sock")
    {:ok, stale} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
    :ok = :gen_tcp.close(stale)
    assert File.exists?(path)
    refute Api.listening?(path)

    {:ok, _} = start_api(path, :api)
    assert Api.listening?(path)
  end

  test "listening?/1: nothing at the path is not a daemon", %{dir: dir} do
    refute Api.listening?(Path.join(dir, "none.sock"))
    File.write!(Path.join(dir, "file"), "")
    refute Api.listening?(Path.join(dir, "file"))
  end
end
