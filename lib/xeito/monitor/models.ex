defmodule Xeito.Monitor.Models do
  @moduledoc """
  Probes whether each local tier's service answers, and which models it holds.

  A local tier is probed through its backend (`Xeito.Tiers.backend/2`) with one HTTP GET bounded
  by `:timeout`. Remote tiers are not probed, they report only `configured: true`. A tier
  without a configuration is `configured: false`.

  What a local tier reports beyond `configured: true` and its `model` is its backend's
  `probe/2` (`Xeito.Backends.probe/3`): `up`, and `loaded`, the models the service holds.
  """

  alias Xeito.Backends
  alias Xeito.Tiers

  @doc """
  Probes every tier. Options: `:tiers` (config overrides per tier), `:timeout`, and `:now`, the
  time the seconds to unload count from (the current time by default).
  """
  @spec read(keyword()) :: map()
  def read(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 800)
    overrides = Keyword.get(opts, :tiers, [])
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    # The probes run concurrently, so one stalled service costs one timeout, not three.
    Tiers.all()
    |> Task.async_stream(
      fn tier -> {tier, probe(tier, Tiers.config(tier, Keyword.get(overrides, tier, [])), timeout, now)} end,
      timeout: timeout * 3,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, pair} -> [pair]
      {:exit, _} -> []
    end)
    |> Map.new()
  end

  defp probe(_tier, nil, _timeout, _now), do: %{configured: false}

  defp probe(tier, cfg, timeout, now) do
    if tier in Tiers.off_box(), do: %{configured: true}, else: local(Tiers.backend(tier, cfg), cfg, timeout, now)
  end

  defp local(backend, cfg, timeout, now),
    do: Map.merge(%{configured: true, model: cfg[:model]}, Backends.probe(backend, cfg, timeout: timeout, now: now))
end
