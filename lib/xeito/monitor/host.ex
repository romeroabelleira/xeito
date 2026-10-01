defmodule Xeito.Monitor.Host do
  @moduledoc """
  CPU, RAM and GPU readings from `/proc` and `/sys` (Linux). Elsewhere, or where a file is
  missing, the reading is `nil` rather than an error.

  GPUs are the DRM cards that expose `gpu_busy_percent` (the `amdgpu` driver): utilisation,
  VRAM used and total, power (`power1_average` or `power1_input`, µW) and temperatures by label
  (`edge`, `junction`, `mem`, m°C). The card with the most VRAM is marked `primary`, which
  separates a discrete GPU from an integrated one.

  CPU utilisation is the busy share of `/proc/stat` time since the previous reading, so the
  caller keeps the previous counters (`read/2` returns them).
  """

  @doc "Reads the system. `prev` is the CPU counters from the last call (or `nil`)."
  @spec read(map() | nil, keyword()) :: {map(), map() | nil}
  def read(prev, opts \\ []) do
    proc = Keyword.get(opts, :proc, "/proc")
    sys = Keyword.get(opts, :sys, "/sys")
    counters = cpu_counters(proc)

    reading = %{
      cpu: %{
        busy_pct: busy_pct(prev, counters),
        load1: load1(proc),
        cores: :logical_processors_available |> :erlang.system_info() |> cores()
      },
      mem: mem(proc),
      gpus: gpus(sys)
    }

    {reading, counters}
  end

  # --- CPU and memory ----------------------------------------------------------------------

  defp cpu_counters(proc) do
    with {:ok, text} <- File.read(Path.join(proc, "stat")),
         ["cpu" | fields] <- text |> String.split("\n") |> hd() |> String.split() do
      values = Enum.map(fields, &String.to_integer/1)
      # idle + iowait count as not busy.
      idle = Enum.at(values, 3, 0) + Enum.at(values, 4, 0)
      %{total: Enum.sum(values), idle: idle}
    else
      _ -> nil
    end
  end

  defp cores(n) when is_integer(n), do: n
  defp cores(_unknown), do: :erlang.system_info(:schedulers_online)

  defp busy_pct(%{total: t0, idle: i0}, %{total: t1, idle: i1}) when t1 > t0,
    do: Float.round(100 * (1 - (i1 - i0) / (t1 - t0)), 1)

  defp busy_pct(_prev, _now), do: nil

  defp load1(proc) do
    case File.read(Path.join(proc, "loadavg")) do
      {:ok, text} -> text |> String.split() |> hd() |> String.to_float()
      _ -> nil
    end
  end

  defp mem(proc) do
    with {:ok, text} <- File.read(Path.join(proc, "meminfo")),
         total when is_integer(total) <- kb(text, "MemTotal"),
         avail when is_integer(avail) <- kb(text, "MemAvailable") do
      %{used_bytes: (total - avail) * 1024, total_bytes: total * 1024}
    else
      _ -> nil
    end
  end

  defp kb(text, key) do
    case Regex.run(~r/^#{key}:\s+(\d+) kB/m, text) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  # --- GPUs ----------------------------------------------------------------------------------

  defp gpus(sys) do
    cards =
      sys
      |> Path.join("class/drm/card*/device/gpu_busy_percent")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&gpu(Path.dirname(&1)))

    primary = Enum.max_by(cards, &(&1.vram_total_bytes || 0), fn -> nil end)
    Enum.map(cards, &Map.put(&1, :primary, &1 == primary))
  end

  defp gpu(device) do
    hwmon = device |> Path.join("hwmon/hwmon*") |> Path.wildcard() |> List.first()

    %{
      card: device |> Path.dirname() |> Path.basename(),
      busy_pct: int(Path.join(device, "gpu_busy_percent")),
      vram_used_bytes: int(Path.join(device, "mem_info_vram_used")),
      vram_total_bytes: int(Path.join(device, "mem_info_vram_total")),
      power_w: power(hwmon),
      temps_c: temps(hwmon)
    }
  end

  defp power(nil), do: nil

  defp power(hwmon) do
    case int(Path.join(hwmon, "power1_average")) || int(Path.join(hwmon, "power1_input")) do
      nil -> nil
      microwatts -> Float.round(microwatts / 1_000_000, 1)
    end
  end

  defp temps(nil), do: %{}

  defp temps(hwmon) do
    for input <- Path.wildcard(Path.join(hwmon, "temp*_input")),
        label = label(String.replace_suffix(input, "_input", "_label")),
        millideg = int(input),
        millideg != nil,
        into: %{},
        do: {label, Float.round(millideg / 1000, 1)}
  end

  defp label(path) do
    case File.read(path) do
      {:ok, text} -> String.trim(text)
      _ -> path |> Path.basename() |> String.replace_suffix("_label", "")
    end
  end

  defp int(path) do
    with {:ok, text} <- File.read(path),
         {n, _} <- Integer.parse(String.trim(text)) do
      n
    else
      _ -> nil
    end
  end
end
