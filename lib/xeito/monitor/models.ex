defmodule Xeito.Monitor.Models do
  @moduledoc """
  Whether each local tier's service answers, and what it holds. A local tier is probed through
  its backend (`Xeito.Tiers.backend/2`) with a short HTTP GET (timeout `:timeout`, default
  800 ms). Remote tiers are not probed: they report only whether they are configured, and their
  spend is in the usage line. A tier without a configured URL is `configured: false`.

  | backend       | probe              | reports                                           |
  |---------------|--------------------|---------------------------------------------------|
  | `:ollama`     | `GET /api/ps`      | resident models: VRAM, context, seconds to unload |
  | `:system_one` | laya `GET /health` | up, loaded models                                 |
  """

  alias Xeito.Backends
  alias Xeito.Tiers

  @doc "Probes every tier. Options: `:tiers` (config overrides per tier), `:timeout`."
  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 800)
    overrides = Keyword.get(opts, :tiers, [])

    # The probes run concurrently, so one stalled service costs one timeout, not three.
    Tiers.all()
    |> Task.async_stream(
      fn tier -> {tier, probe(tier, Tiers.config(tier, Keyword.get(overrides, tier, [])), timeout)} end,
      timeout: timeout * 3,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, pair} -> [pair]
      {:exit, _} -> []
    end)
    |> Map.new()
  end

  defp probe(_tier, nil, _timeout), do: %{configured: false}

  defp probe(tier, cfg, timeout) do
    if tier in Tiers.off_box(), do: %{configured: true}, else: local(Tiers.backend(tier, cfg), cfg, timeout)
  end

  defp local(:ollama, cfg, timeout), do: configured(cfg, ollama(cfg, timeout))
  defp local(:system_one, cfg, timeout), do: configured(cfg, system_one(cfg, timeout))
  defp local(_backend, _cfg, _timeout), do: %{configured: true}

  defp configured(cfg, probe), do: Map.merge(%{configured: true, model: cfg[:model]}, probe)

  defp ollama(cfg, timeout) do
    case get(cfg, "/api/ps", timeout) do
      {:ok, %{"models" => models}} ->
        %{up: true, loaded: Enum.map(models, &resident/1)}

      _ ->
        %{up: false, loaded: []}
    end
  end

  defp resident(m) do
    %{
      name: m["name"],
      vram_bytes: m["size_vram"],
      context: m["context_length"],
      unload_in_s: seconds_until(m["expires_at"])
    }
  end

  defp seconds_until(nil), do: nil

  defp seconds_until(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> max(DateTime.diff(at, DateTime.utc_now()), 0)
      _ -> nil
    end
  end

  defp system_one(cfg, timeout) do
    case get(cfg, "/health", timeout) do
      {:ok, %{"status" => "ok"} = body} -> %{up: true, loaded: body["loaded"] || []}
      _ -> %{up: false}
    end
  end

  defp get(cfg, path, timeout) do
    opts = [method: :get, url: path] ++ Backends.req_options(Keyword.put(cfg, :timeout, timeout))

    case Req.request(Keyword.put(opts, :connect_options, timeout: timeout)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _ -> :error
    end
  end
end
