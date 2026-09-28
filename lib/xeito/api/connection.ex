defmodule Xeito.Api.Connection do
  @moduledoc "One client connection of `Xeito.Api`: decodes request lines, replies, forwards events."

  use GenServer, restart: :temporary

  alias Xeito.Log.Codec
  alias Xeito.{Monitor, Session}
  alias Xeito.Session.Router

  @max_line 4_194_304

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts),
    do: {:ok, %{socket: opts[:socket], buffer: "", defaults: opts[:session], sessions: %{}}}

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

  def handle_info({:xeito, "session:" <> session, event}, s) do
    send_line(s, %{event: event.type, session: session, run: event.run, attrs: event.attrs})
    {:noreply, s}
  end

  def handle_info({:xeito_monitor, snapshot}, s) do
    send_line(s, %{event: "monitor", attrs: snapshot})
    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

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

  defp handle("start", req, s) do
    opts = Keyword.merge(s.defaults, cwd: req["cwd"] || File.cwd!())

    case Session.start(opts) do
      {:ok, id} -> {%{ok: true, session: id}, follow(s, id, opts[:cwd])}
      {:error, reason} -> {%{ok: false, error: inspect(reason)}, s}
    end
  end

  defp handle("attach", %{"session" => id} = req, s) do
    cond do
      exists?(id) ->
        status = Session.status(id)
        {%{ok: true, session: id, status: status}, follow(s, id, status.cwd)}

      req["cwd"] ->
        handle("resume", req, s)

      true ->
        {%{ok: false, error: "no such session"}, s}
    end
  end

  # A session the daemon no longer holds (it restarted) is rebuilt from the workspace log.
  defp handle("resume", %{"session" => id} = req, s) do
    opts = Keyword.merge(s.defaults, id: id, cwd: req["cwd"] || File.cwd!())

    case Session.start(opts) do
      {:ok, ^id} ->
        {%{ok: true, session: id, status: Session.status(id)}, follow(s, id, opts[:cwd])}

      {:error, reason} ->
        {%{ok: false, error: inspect(reason)}, s}
    end
  end

  # Status-bar data: the connection receives monitor snapshots while it is subscribed.
  defp handle("monitor", req, s) do
    if req["on"] == false,
      do: Monitor.unsubscribe(self()),
      else: Monitor.subscribe(self())

    {%{ok: true}, s}
  end

  defp handle("machines", req, s) do
    cwd = req["cwd"] || (req["session"] && s.sessions[req["session"]]) || File.cwd!()
    {%{ok: true, machines: Router.describe(cwd)}, s}
  end

  defp handle("sessions", _req, s) do
    ids = Registry.select(Xeito.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    {%{ok: true, sessions: Enum.map(ids, &Session.status/1)}, s}
  end

  # A followed session that closed while idle is resumed transparently from its workspace log.
  defp handle(cmd, %{"session" => id} = req, s)
       when cmd in ~w(prompt approve deny status history) do
    cond do
      exists?(id) ->
        {session_cmd(cmd, id, req), s}

      cwd = s.sessions[id] ->
        case handle("resume", %{"session" => id, "cwd" => cwd}, s) do
          {%{ok: true}, s} -> {session_cmd(cmd, id, req), s}
          failed -> failed
        end

      true ->
        {%{ok: false, error: "no such session"}, s}
    end
  end

  defp handle(cmd, _req, s), do: {%{ok: false, error: "unknown or incomplete command #{cmd}"}, s}

  defp session_cmd("prompt", id, req), do: result(Session.prompt(id, req["text"] || ""))
  defp session_cmd("approve", id, _req), do: result(Session.approve(id))
  defp session_cmd("deny", id, _req), do: result(Session.deny(id))
  defp session_cmd("status", id, _req), do: %{ok: true, status: Session.status(id)}
  defp session_cmd("history", id, _req), do: %{ok: true, history: Session.history(id)}

  defp result(:ok), do: %{ok: true}
  defp result({:error, reason}), do: %{ok: false, error: to_string(reason)}

  defp exists?(id), do: Registry.lookup(Xeito.SessionRegistry, id) != []

  # Remembers the workspace of every followed session, so it can be resumed after an idle close.
  defp follow(s, id, cwd) do
    unless Map.has_key?(s.sessions, id), do: Session.subscribe(id)
    %{s | sessions: Map.put(s.sessions, id, cwd)}
  end

  defp send_line(s, map), do: :gen_tcp.send(s.socket, [Codec.encode(map), "\n"])
end
