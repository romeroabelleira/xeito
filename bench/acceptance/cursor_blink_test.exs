# Acceptance check for the code-navigation benchmark task (bench/4-harness.md): "the text cursor
# in the TUI's input field blinks; the `> ` prompt marker does not change".
#
# Copied into a benchmark workspace's test/ directory only after the run, so the model never sees
# it. It drives `Xeito.Tui` the way TermUI's runtime does, without a terminal:
#   * `init/1` against a fake daemon (a Unix socket answering every request with ok);
#   * the commands `init`/`update` return (timer, interval, send_after) become real timers whose
#     messages are fed to `update/2`; other messages (e.g. from Process.send_after) go to
#     `handle_info/2`;
#   * every state is rendered with `view/1` for three seconds.
#
# It passes when the input's cursor cell (TextInput draws it in reverse video; the header is
# reverse video too, so it shows as one more reverse-styled node) is drawn in some frames and
# hidden in others, toggling between 2 and 12 times in three seconds (about 0.3 to 2 Hz), and
# every frame shows the `> ` marker.
defmodule Xeito.AcceptanceCursorBlinkTest do
  use ExUnit.Case, async: false

  @duration 3_000

  setup do
    dir = Path.join(System.tmp_dir!(), "xeito-accept-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    socket = Path.join(dir, "d.sock")
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, socket}, packet: :line, active: false])
    server = spawn_link(fn -> serve(listen) end)
    previous = Application.get_env(:xeito, :tui)
    Application.put_env(:xeito, :tui, socket: socket, cwd: dir)
    System.put_env("XEITO_TUI_CONFIG", Path.join(dir, "none.json"))

    on_exit(fn ->
      Process.exit(server, :kill)
      if previous, do: Application.put_env(:xeito, :tui, previous), else: Application.delete_env(:xeito, :tui)
      System.delete_env("XEITO_TUI_CONFIG")
      File.rm_rf(dir)
    end)

    :ok
  end

  defp serve(listen) do
    {:ok, conn} = :gen_tcp.accept(listen)
    reply(conn)
  end

  defp reply(conn) do
    case :gen_tcp.recv(conn, 0) do
      {:ok, line} ->
        %{"id" => id} = JSON.decode!(line)
        reply = %{id: id, ok: true, session: "ses-accept", status: %{cwd: "/w"}, history: []}
        :ok = :gen_tcp.send(conn, [JSON.encode!(reply), "\n"])
        reply(conn)

      {:error, _} ->
        :ok
    end
  end

  test "the input cursor blinks and the prompt marker stays" do
    {state, commands} = TermUI.Elm.normalize_init_result(Xeito.Tui.init([]))
    arm(commands)
    frames = drive(state, System.monotonic_time(:millisecond) + @duration, [frame(state)])

    header = frames |> Enum.map(& &1.reverse) |> Enum.min()
    drawn = Enum.map(frames, &(&1.reverse > header))
    toggles = drawn |> Enum.chunk_every(2, 1, :discard) |> Enum.count(fn [a, b] -> a != b end)

    assert Enum.all?(frames, & &1.marker), "the `> ` prompt marker must be shown in every frame"
    assert true in drawn and false in drawn, "the cursor must be drawn in some frames and hidden in others"
    assert toggles in 2..12, "expected the cursor to toggle 2-12 times in 3 s, got #{toggles}"
  end

  # Commands become real timers; their messages are tagged so they go to update/2.
  defp arm(commands) do
    for %TermUI.Command{type: type, payload: payload, on_result: msg} <- List.wrap(commands) do
      case type do
        :timer -> Process.send_after(self(), {:__update, msg}, payload)
        :interval -> Process.send_after(self(), {:__interval, payload, msg}, payload)
        :send_after -> {_target, m, delay} = payload; Process.send_after(self(), {:__update, m}, delay)
        _ -> :ok
      end
    end
  end

  defp drive(state, deadline, frames) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      Enum.reverse(frames)
    else
      receive do
        {:__interval, ms, msg} ->
          Process.send_after(self(), {:__interval, ms, msg}, ms)
          step(state, &Xeito.Tui.update(msg, &1), deadline, frames)

        {:__update, msg} ->
          step(state, &Xeito.Tui.update(msg, &1), deadline, frames)

        other ->
          if function_exported?(Xeito.Tui, :handle_info, 2),
            do: step(state, &Xeito.Tui.handle_info(other, &1), deadline, frames),
            else: drive(state, deadline, frames)
      after
        left -> Enum.reverse(frames)
      end
    end
  end

  defp step(state, fun, deadline, frames) do
    {state, commands} = TermUI.Elm.normalize_update_result(fun.(state), state)
    arm(commands)
    drive(state, deadline, [frame(state) | frames])
  end

  defp frame(state) do
    tree = state |> Xeito.Tui.view() |> inspect(limit: :infinity, printable_limit: :infinity)
    %{reverse: length(String.split(tree, ":reverse")) - 1, marker: String.contains?(tree, ~s("> "))}
  end
end
