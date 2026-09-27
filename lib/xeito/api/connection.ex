defmodule Xeito.Api.Connection do
  @moduledoc "One client connection of `Xeito.Api`: decodes request lines, replies, forwards events."

  use GenServer, restart: :temporary

  alias Xeito.Log.Codec
  alias Xeito.Session

  @max_line 4_194_304

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts),
    do:
      {:ok,
       %{socket: opts[:socket], buffer: "", defaults: opts[:session], sessions: MapSet.new()}}

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
      {:ok, id} -> {%{ok: true, session: id}, follow(s, id)}
      {:error, reason} -> {%{ok: false, error: inspect(reason)}, s}
    end
  end

  defp handle("attach", %{"session" => id} = req, s) do
    cond do
      exists?(id) -> {%{ok: true, session: id, status: Session.status(id)}, follow(s, id)}
      req["cwd"] -> handle("resume", req, s)
      true -> {%{ok: false, error: "no such session"}, s}
    end
  end

  # A session the daemon no longer holds (it restarted) is rebuilt from the workspace log.
  defp handle("resume", %{"session" => id} = req, s) do
    opts = Keyword.merge(s.defaults, id: id, cwd: req["cwd"] || File.cwd!())

    case Session.start(opts) do
      {:ok, ^id} -> {%{ok: true, session: id, status: Session.status(id)}, follow(s, id)}
      {:error, reason} -> {%{ok: false, error: inspect(reason)}, s}
    end
  end

  defp handle("sessions", _req, s) do
    ids = Registry.select(Xeito.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    {%{ok: true, sessions: Enum.map(ids, &Session.status/1)}, s}
  end

  defp handle(cmd, %{"session" => id} = req, s)
       when cmd in ~w(prompt approve deny status history) do
    if exists?(id),
      do: {session_cmd(cmd, id, req), s},
      else: {%{ok: false, error: "no such session"}, s}
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

  defp follow(s, id) do
    if MapSet.member?(s.sessions, id) do
      s
    else
      Session.subscribe(id)
      %{s | sessions: MapSet.put(s.sessions, id)}
    end
  end

  defp send_line(s, map), do: :gen_tcp.send(s.socket, [Codec.encode(map), "\n"])
end
