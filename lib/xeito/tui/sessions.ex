defmodule Xeito.Tui.Sessions do
  @moduledoc """
  `/sessions` in the TUI: the directory's sessions, last updated first (`/sessions`), switching
  to one of them (`/sessions N`) or starting another (`/sessions new`).

  The daemon answers asynchronously, so a request carries a tag and its reply comes back to the
  TUI as `{:xeito_reply, tag, reply}`, handled by `reply/3`. A switch resets what the TUI shows
  to the new session: its earlier turns, an idle status, no queue. The previous session keeps
  running in the daemon.
  """

  alias Xeito.Client
  alias Xeito.Client.StatusBar
  alias Xeito.Tui

  @doc "Runs `/sessions` with its argument: none, a number from the last list, or `new`."
  @spec command(String.t(), map()) :: map()
  def command("", state), do: ask(state, :sessions, %{"cmd" => "sessions", "cwd" => state.cwd})
  def command("new", state), do: ask(state, :switched, %{"cmd" => "start", "cwd" => state.cwd})

  def command(number, state) do
    case pick(number, state.listed) do
      nil -> Tui.append(state, "no session #{number}: /sessions lists them\n")
      id -> ask(state, :switched, %{"cmd" => "attach", "session" => id, "cwd" => state.cwd})
    end
  end

  defp pick(number, listed) do
    case Integer.parse(number) do
      {n, ""} when n >= 1 -> Enum.at(listed, n - 1)
      _ -> nil
    end
  end

  @doc "Applies the daemon's reply to a tagged request."
  @spec reply(term(), map(), map()) :: map()
  def reply(:sessions, %{"ok" => true, "sessions" => sessions}, state), do: list(sessions, state)
  def reply(:switched, %{"ok" => true, "session" => id}, state), do: switch(id, state)

  def reply({:earlier, id}, %{"ok" => true, "turns" => turns}, %{session: id} = state),
    do: %{state | lines: Tui.transcript_lines(turns) ++ state.lines}

  def reply(_tag, %{"ok" => false, "error" => error}, state), do: Tui.append(state, "✗ #{error}\n")
  def reply(_tag, _reply, state), do: state

  defp list(sessions, state) do
    rows = sessions |> Enum.with_index(1) |> Enum.map(fn {session, n} -> row(session, n, state.session) end)
    lines = ["sessions in #{state.cwd}, last updated first:"] ++ rows ++ [footer()]
    %{state | listed: Enum.map(sessions, & &1["id"]), lines: state.lines ++ lines}
  end

  defp footer, do: "/sessions N switches to one · /sessions new starts another"

  defp row(%{"id" => id} = session, n, current) do
    "  #{n}  #{id} · #{local_time(session["last"])} · #{prompts(session["prompts"])}" <>
      last_prompt(session["last_prompt"]) <> if(id == current, do: "  (this one)", else: "")
  end

  defp prompts(1), do: "1 prompt"
  defp prompts(n), do: "#{n} prompts"

  defp last_prompt(nil), do: ""
  defp last_prompt(text), do: " · > " <> (text |> String.split("\n") |> hd() |> String.slice(0, 60))

  # Logged times are UTC; the list shows them in the machine's time zone.
  defp local_time(iso) do
    case DateTime.from_iso8601(to_string(iso)) do
      {:ok, at, _offset} ->
        at
        |> DateTime.to_naive()
        |> NaiveDateTime.to_erl()
        |> :calendar.universal_time_to_local_time()
        |> NaiveDateTime.from_erl!()
        |> Calendar.strftime("%Y-%m-%d %H:%M")

      _ ->
        to_string(iso)
    end
  end

  defp switch(id, state) do
    state = %{
      state
      | session: id,
        lines: [Tui.header(id, false)],
        partial: "",
        scroll: 0,
        machine: nil,
        leaf: "idle",
        started: nil,
        decisions: 0,
        tier: nil,
        usd: 0.0,
        waiting: false,
        paused: false,
        queue: [],
        held: false,
        marker: nil,
        usage: StatusBar.new(),
        workspace: nil,
        workspace_at: nil
    }

    state
    |> ask({:earlier, id}, %{"cmd" => "transcript", "session" => id, "cwd" => state.cwd})
    |> ask(:workspace, %{"cmd" => "workspace", "session" => id})
  end

  # Requests are sent from a task, so the UI never waits on the daemon.
  defp ask(state, tag, req) do
    me = self()
    Task.start(fn -> send(me, {:xeito_reply, tag, Client.request(state.client, req)}) end)
    state
  end
end
