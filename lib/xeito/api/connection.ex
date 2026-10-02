defmodule Xeito.Api.Connection do
  @moduledoc "One client connection of `Xeito.Api`: decodes request lines, replies, forwards events."

  use GenServer, restart: :temporary

  alias Xeito.Log.Codec
  alias Xeito.Monitor
  alias Xeito.Session
  alias Xeito.Session.Router

  @max_line 4_194_304

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, %{socket: opts[:socket], buffer: "", defaults: opts[:session], sessions: %{}}}

  @impl true
  def handle_info(:go, s) do
    :inet.setopts(s.socket, active: :once)
    {:noreply, s}
  end

  def handle_info({:tcp, socket, data}, s) do
    {lines, rest} = split(s.buffer <> data)
    s = Enum.reduce(lines, %{s | buffer: rest}, &handle_line/2)

    if byte_size(s.buffer) > @max_line do
      {:stop, :normal, s}
    else
      :inet.setopts(socket, active: :once)
      {:noreply, s}
    end
  end

  def handle_info({:tcp_closed, _}, s), do: {:stop, :normal, s}
  def handle_info({:tcp_error, _, _}, s), do: {:stop, :normal, s}

  def handle_info(msg, s) do
    forward(msg, s)
    {:noreply, s}
  end

  # Session events and monitor snapshots go to the client as they come.
  defp forward({:xeito, "session:" <> session, event}, s),
    do: send_line(s, %{event: event.type, session: session, run: event.run, attrs: event.attrs})

  defp forward({:xeito_monitor, snapshot}, s), do: send_line(s, %{event: "monitor", attrs: snapshot})
  defp forward(_msg, _s), do: :ok

  defp split(buffer) do
    parts = String.split(buffer, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp handle_line(line, s) do
    case JSON.decode(String.trim(line)) do
      {:ok, %{"cmd" => cmd} = req} ->
        {reply, s} = handle(cmd, req, s)
        send_line(s, Map.put(reply, :id, req["id"]))
        s

      {:ok, _} ->
        send_line(s, %{ok: false, error: "missing cmd"})
        s

      {:error, _} when line == "" ->
        s

      {:error, _} ->
        send_line(s, %{ok: false, error: "invalid JSON"})
        s
    end
  end

  defp handle(cmd, req, s) when cmd in ~w(start attach resume), do: open_session(cmd, req, s)
  defp handle(cmd, req, s) when cmd in ~w(monitor machines sessions), do: daemon_request(cmd, req, s)

  # A followed session that closed while idle is resumed transparently from its workspace log.
  defp handle(cmd, %{"session" => id} = req, s) when cmd in ~w(prompt approve deny status history workspace),
    do: session_request(cmd, id, req, s)

  defp handle(cmd, _req, s), do: unknown(cmd, s)

  defp unknown(cmd, s), do: {%{ok: false, error: "unknown or incomplete command #{cmd}"}, s}

  defp open_session("start", req, s), do: start_session(Keyword.put(s.defaults, :cwd, workspace(req)), s)
  defp open_session("attach", %{"session" => id} = req, s), do: attach(id, req, s)
  defp open_session("resume", %{"session" => id} = req, s), do: resume(id, workspace(req), s)
  defp open_session(cmd, _req, s), do: unknown(cmd, s)

  defp workspace(req), do: req["cwd"] || File.cwd!()

  defp start_session(opts, s) do
    case Session.start(opts) do
      {:ok, id} -> {%{ok: true, session: id}, follow(s, id, opts[:cwd])}
      {:error, reason} -> {%{ok: false, error: inspect(reason)}, s}
    end
  end

  defp attach(id, req, s) do
    cond do
      exists?(id) ->
        status = Session.status(id)
        {%{ok: true, session: id, status: status}, follow(s, id, status.cwd)}

      req["cwd"] ->
        resume(id, req["cwd"], s)

      true ->
        {%{ok: false, error: "no such session"}, s}
    end
  end

  # A session the daemon no longer holds (it restarted) is rebuilt from the workspace log.
  defp resume(id, cwd, s) do
    case Session.start(Keyword.merge(s.defaults, id: id, cwd: cwd)) do
      {:ok, ^id} -> {%{ok: true, session: id, status: Session.status(id)}, follow(s, id, cwd)}
      {:error, reason} -> {%{ok: false, error: inspect(reason)}, s}
    end
  end

  # Status-bar data: the connection receives monitor snapshots while it is subscribed.
  defp daemon_request("monitor", req, s) do
    if req["on"] == false, do: Monitor.unsubscribe(self()), else: Monitor.subscribe(self())
    {%{ok: true}, s}
  end

  defp daemon_request("machines", req, s), do: {%{ok: true, machines: Router.describe(machines_cwd(req, s))}, s}

  defp daemon_request("sessions", _req, s) do
    ids = Registry.select(Xeito.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    {%{ok: true, sessions: Enum.map(ids, &Session.status/1)}, s}
  end

  defp machines_cwd(req, s), do: req["cwd"] || (req["session"] && s.sessions[req["session"]]) || File.cwd!()

  defp session_request(cmd, id, req, s) do
    cond do
      exists?(id) -> {session_cmd(cmd, id, req), s}
      cwd = s.sessions[id] -> resume_then(cmd, id, req, cwd, s)
      true -> {%{ok: false, error: "no such session"}, s}
    end
  end

  defp resume_then(cmd, id, req, cwd, s) do
    case resume(id, cwd, s) do
      {%{ok: true}, s} -> {session_cmd(cmd, id, req), s}
      failed -> failed
    end
  end

  defp session_cmd("prompt", id, req), do: result(Session.prompt(id, req["text"] || ""))
  defp session_cmd(cmd, id, _req) when cmd in ~w(approve deny), do: result(answer(cmd, id))
  defp session_cmd(cmd, id, _req), do: query(cmd, id)

  defp answer("approve", id), do: Session.approve(id)
  defp answer("deny", id), do: Session.deny(id)

  defp query("status", id), do: %{ok: true, status: Session.status(id)}
  defp query("history", id), do: %{ok: true, history: Session.history(id)}
  defp query("workspace", id), do: %{ok: true, workspace: Session.workspace(id)}

  defp result(:ok), do: %{ok: true}
  defp result({:error, reason}), do: %{ok: false, error: to_string(reason)}

  defp exists?(id), do: Registry.lookup(Xeito.SessionRegistry, id) != []

  # Remembers the workspace of every followed session, so it can be resumed after an idle close.
  defp follow(s, id, cwd) do
    if !Map.has_key?(s.sessions, id), do: Session.subscribe(id)
    %{s | sessions: Map.put(s.sessions, id, cwd)}
  end

  defp send_line(s, map), do: :gen_tcp.send(s.socket, [Codec.encode(map), "\n"])
end
