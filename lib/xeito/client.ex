defmodule Xeito.Client do
  @moduledoc """
  A client of `Xeito.Api`: connects to the daemon's socket, sends requests and forwards events.
  It needs nothing from the daemon's code beyond the protocol, so the TUI and the CLI stay thin.

  Events are sent to the owner (the process that called `connect/2`) as `{:xeito_event, map}`,
  with string keys as decoded from JSON.
  """

  use GenServer

  @doc "Connects to the socket at `path`. The caller becomes the owner of events."
  @spec connect(Path.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def connect(path, owner \\ self()) do
    # Linked only once connected: a failed start would otherwise take the caller down with it,
    # instead of returning the error.
    with {:ok, client} <- GenServer.start(__MODULE__, {path, owner}) do
      Process.link(client)
      {:ok, client}
    end
  end

  @doc "Sends a request (a map with `\"cmd\"`) and waits for its reply."
  @spec request(pid(), map(), timeout()) :: map()
  def request(client, req, timeout \\ 30_000), do: GenServer.call(client, {:request, req}, timeout)

  @impl true
  def init({path, owner}) do
    case :gen_tcp.connect({:local, path}, 0, [:binary, active: :once, packet: :raw]) do
      {:ok, socket} -> {:ok, %{socket: socket, owner: owner, buffer: "", next: 1, waiting: %{}}}
      {:error, reason} -> {:stop, {:connect_failed, path, reason}}
    end
  end

  @impl true
  def handle_call({:request, req}, from, s) do
    id = s.next
    :ok = :gen_tcp.send(s.socket, [JSON.encode!(Map.put(req, "id", id)), "\n"])
    {:noreply, %{s | next: id + 1, waiting: Map.put(s.waiting, id, from)}}
  end

  @impl true
  def handle_info({:tcp, socket, data}, s) do
    parts = String.split(s.buffer <> data, "\n")
    {lines, [rest]} = Enum.split(parts, -1)
    s = Enum.reduce(lines, %{s | buffer: rest}, &line/2)
    :inet.setopts(socket, active: :once)
    {:noreply, s}
  end

  def handle_info({:tcp_closed, _}, s) do
    send(s.owner, {:xeito_event, %{"event" => "disconnected"}})
    {:stop, :normal, s}
  end

  defp line("", s), do: s

  defp line(text, s) do
    case JSON.decode(text) do
      {:ok, %{"event" => _} = event} ->
        send(s.owner, {:xeito_event, event})
        s

      {:ok, %{"id" => id} = reply} ->
        {from, waiting} = Map.pop(s.waiting, id)
        if from, do: GenServer.reply(from, reply)
        %{s | waiting: waiting}

      _ ->
        s
    end
  end
end
