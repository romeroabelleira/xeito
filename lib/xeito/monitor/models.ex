defmodule Xeito.Monitor.Models do
  @moduledoc """
  Whether each tier's service answers, and what it holds. Every probe is a short local HTTP GET
  (timeout `:timeout`, default 800 ms); a tier without a configured URL is `configured: false`.

  | tier          | probe                        | reports                                         |
  |---------------|------------------------------|-------------------------------------------------|
  | `:large`      | Ollama `GET /api/ps`         | resident models: VRAM, context, seconds to unload |
  | `:small`      | llama-server `/health`, `/slots` | up, busy and total slots                     |
  | `:system_one` | laya `GET /health`           | up, loaded models                               |
  | `:openrouter`, `:remote` | none (off-box)    | configured or not; spend is in the usage line   |
  """

  alias Xeito.Tiers

  @doc "Probes every tier. Options: `:tiers` (config overrides per tier), `:timeout`."
  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 800)
    overrides = Keyword.get(opts, :tiers, [])
    cfg = &Tiers.config(&1, Keyword.get(overrides, &1, []))

    # The local probes run concurrently, so one stalled service costs one timeout, not three.
    local =
      [
        large: &large(&1, timeout),
        small: &small(&1, timeout),
        system_one: &system_one(&1, timeout)
      ]
      |> Task.async_stream(fn {tier, fun} -> {tier, probe(cfg.(tier), fun)} end,
        timeout: timeout * 3,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, pair} -> [pair]
        {:exit, _} -> []
      end)
      |> Map.new()

    Map.merge(local, %{
      openrouter: %{configured: cfg.(:openrouter) != nil},
      remote: %{configured: cfg.(:remote) != nil}
    })
  end

  defp probe(nil, _fun), do: %{configured: false}
  defp probe(cfg, fun), do: Map.merge(%{configured: true, model: cfg[:model]}, fun.(cfg))

  defp large(cfg, timeout) do
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

  defp small(cfg, timeout) do
    case get(cfg, "/health", timeout) do
      {:ok, %{"status" => "ok"}} ->
        Map.merge(%{up: true}, slots(cfg, timeout))

      _ ->
        %{up: false}
    end
  end

  defp slots(cfg, timeout) do
    case get(cfg, "/slots", timeout) do
      {:ok, slots} when is_list(slots) ->
        %{slots: length(slots), busy: Enum.count(slots, &(&1["is_processing"] == true))}

      _ ->
        %{}
    end
  end

  defp system_one(cfg, timeout) do
    case get(cfg, "/health", timeout) do
      {:ok, %{"status" => "ok"} = body} -> %{up: true, loaded: body["loaded"] || []}
      _ -> %{up: false}
    end
  end

  defp get(cfg, path, timeout) do
    opts = [method: :get, url: path] ++ Tiers.req_options(Keyword.put(cfg, :timeout, timeout))

    case Req.request(Keyword.put(opts, :connect_options, timeout: timeout)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _ -> :error
    end
  end
end
