defmodule Xeito.Session.DirectoryTest do
  use Xeito.Case, async: false

  alias Xeito.Log
  alias Xeito.Log.Event
  alias Xeito.Machines.Chat
  alias Xeito.Session
  alias Xeito.Session.Directory

  setup do
    root = Path.join(System.tmp_dir!(), "xeito-dir-#{System.unique_integer([:positive])}")
    [ws, other] = for name <- ~w(ws other), do: Path.join(root, name)
    Enum.each([ws, other], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(root) end)
    %{log: start_log!(), ws: ws, other: other}
  end

  defp session(log, cwd) do
    {:ok, id} = Session.start(cwd: cwd, log: log, id: "ses-d-#{System.unique_integer([:positive])}")
    id
  end

  # Commands start a turn without a model; the prompt is logged like any other.
  defp say(id, text), do: :ok = Session.prompt(id, text)

  # A session from before prompts were logged: only its turns' runs say what was asked.
  defp old_session(log, cwd, request) do
    id = "ses-old-#{System.unique_integer([:positive])}"
    Log.put_object(log, id, "session", %{cwd: cwd, status: "closed"})
    started(log, id <> "/t1", %{prompt: "Use the skill …\n\n" <> request, request: request})
    started(log, id <> "/t1/intent", %{input: %{message: "not a turn"}})
    id
  end

  defp started(log, run, input) do
    attrs = %{"machine" => "chat", "machine_version" => "0.9.0", "input" => input}
    {:ok, _} = Log.append(log, run, [Event.new("run_started", {:run_started, Chat, "0.9.0", input}, attrs)])
  end

  test "a directory's sessions, the last updated first, with their prompts", %{log: log, ws: ws, other: other} do
    old = old_session(log, ws, "fix the banner")
    a = session(log, ws)
    say(a, "/help")
    say(a, "/why")
    b = session(log, ws)
    say(b, "/help")
    say(session(log, other), "/why")

    assert [
             %{id: ^b, prompts: 1, last_prompt: "/help", last: last_b},
             %{id: ^a, prompts: 2, last_prompt: "/why"},
             %{id: ^old, prompts: 1, last_prompt: "fix the banner"}
           ] = Directory.sessions(log, ws)

    assert is_binary(last_b)
    assert Directory.latest(log, ws) == b
    assert Directory.latest(log, Path.join(other, "none")) == nil
  end

  test "a session opened but never prompted is listed, and is the latest until another is used", %{log: log, ws: ws} do
    a = session(log, ws)
    say(a, "/help")
    fresh = session(log, ws)
    assert [%{id: ^fresh, prompts: 0, last_prompt: nil}, %{id: ^a}] = Directory.sessions(log, ws)
    assert Directory.latest(log, ws) == fresh
  end

  test "the prompts typed in a directory, newest first, each once", %{log: log, ws: ws, other: other} do
    old_session(log, ws, "fix the banner")
    a = session(log, ws)
    say(a, "/help")
    say(a, "/why")
    say(session(log, ws), "/help")
    say(session(log, other), "/machines")

    assert Directory.prompts(log, ws) == ["/help", "/why", "fix the banner"]
    assert Directory.prompts(log, ws, 2) == ["/help", "/why"]
  end
end
