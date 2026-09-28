defmodule Xeito.Client.StatusBar do
  @moduledoc """
  The TUI's toggleable status bar, as pure functions: usage is counted from the daemon events a
  client already receives, and hardware and model status come from `Xeito.Monitor` snapshots.

      GPU 18.5/24.0 GiB 97% 290 W 61°C │ large qwen3.6:27b unload 4:12 │ small ✓ 1/4 │ S1 ✓ │ CPU 23% load 1.2 RAM 17.1/62.0 GiB
      large 12 · small 3 · rule 9 · human 1 │ 18.4k→1.2k tok · ctx 3.2k/81.9k │ det 45% │ $0.0000 · ~2.1 kJ │ queue large 1+2

  * **Calls** per actor: decisions (`decision_made`, `intent`) and chat turns (`chat`).
  * **Tokens** in → out over the session, and **ctx**: the prompt size of the last chat turn
    against the resident model's context window, i.e. how full the context is.
  * **det**: the determinism budget, the share of transitions taken by code or rules rather than
    models or humans (`docs/architecture/01-principles.md#2-the-determinism-budget`).
  * **Spend** on off-box tiers and the estimated energy of local decisions.
  * **Queue**: tiers with calls in flight or waiting.
  """

  @type usage :: %{
          calls: %{String.t() => non_neg_integer()},
          tokens_in: non_neg_integer(),
          tokens_out: non_neg_integer(),
          ctx: non_neg_integer() | nil,
          usd: float(),
          joules: float(),
          det: {non_neg_integer(), non_neg_integer()}
        }

  @doc "Empty usage counters."
  @spec new() :: usage()
  def new,
    do: %{calls: %{}, tokens_in: 0, tokens_out: 0, ctx: nil, usd: 0.0, joules: 0.0, det: {0, 0}}

  @doc "Counts one daemon event (string keys, as decoded from the API)."
  @spec count(usage(), map()) :: usage()
  def count(usage, %{"event" => event, "run" => run} = e) when is_binary(run) do
    if internal?(run), do: usage, else: count_event(usage, event, e)
  end

  def count(usage, %{"event" => event} = e), do: count_event(usage, event, e)

  defp count_event(usage, type, %{"attrs" => a}) when type in ["decision_made", "intent"] do
    usage
    |> call(to_string(a["actor"] || "none"))
    |> add_cost(a)
  end

  defp count_event(usage, "effect_completed", %{"attrs" => %{"kind" => kind, "result" => r}})
       when kind in ["chat", :chat] and is_map(r) do
    usage
    |> call("chat")
    |> add_cost(r)
    |> Map.put(:ctx, r["tokens_in"] || usage.ctx)
  end

  defp count_event(usage, "transition", %{"attrs" => %{"actor" => actor}}) do
    {code, total} = usage.det
    code = if to_string(actor) in ["code", "rule"], do: code + 1, else: code
    %{usage | det: {code, total + 1}}
  end

  defp count_event(usage, _type, _event), do: usage

  defp call(usage, actor), do: %{usage | calls: Map.update(usage.calls, actor, 1, &(&1 + 1))}

  defp add_cost(usage, a) do
    %{
      usage
      | tokens_in: usage.tokens_in + num(a["tokens_in"]),
        tokens_out: usage.tokens_out + num(a["tokens_out"]),
        usd: usage.usd + num(a["usd"]),
        joules: usage.joules + num(a["joules_est"])
    }
  end

  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  defp internal?(run), do: String.ends_with?(run, "/esc") or String.ends_with?(run, "/intent")

  # --- rendering -------------------------------------------------------------------------

  @doc "The two bar lines: machine and models (from a monitor snapshot, if any), then usage."
  @spec lines(usage(), map() | nil) :: [String.t()]
  def lines(usage, monitor), do: [system_line(monitor), usage_line(usage, monitor)]

  @doc false
  def system_line(nil), do: "status: waiting for the daemon's monitor…"

  def system_line(%{"system" => sys, "models" => models}) do
    [
      gpu(sys["gpus"]),
      large(models["large"]),
      small(models["small"]),
      s1(models["system_one"]),
      cpu(sys)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" │ ")
  end

  @doc false
  def usage_line(usage, monitor) do
    calls =
      case usage.calls |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {a, n} -> "#{a} #{n}" end) do
        [] -> "no model calls yet"
        parts -> Enum.join(parts, " · ")
      end

    tokens = "#{k(usage.tokens_in)}→#{k(usage.tokens_out)} tok" <> ctx(usage.ctx, monitor)

    {code, total} = usage.det
    det = if total > 0, do: "det #{round(100 * code / total)}%", else: "det -"
    cost = "$#{:erlang.float_to_binary(usage.usd * 1.0, decimals: 4)} · ~#{energy(usage.joules)}"

    [calls, tokens, det, cost, queues(monitor)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" │ ")
  end

  defp gpu(gpus) when is_list(gpus) do
    case Enum.find(gpus, & &1["primary"]) do
      nil ->
        ""

      g ->
        temp = g["temps_c"]["junction"] || g["temps_c"]["edge"]

        "GPU #{gb(g["vram_used_bytes"])}/#{gb(g["vram_total_bytes"])} GiB #{g["busy_pct"]}%" <>
          opt(g["power_w"], &" #{round(&1)} W") <> opt(temp, &" #{round(&1)}°C")
    end
  end

  defp gpu(_), do: ""

  defp large(%{"configured" => true, "up" => true, "loaded" => [m | _]}),
    do: "large #{m["name"]}" <> opt(m["unload_in_s"], &" unload #{mmss(&1)}")

  defp large(%{"configured" => true, "up" => true}), do: "large idle (not loaded)"
  defp large(%{"configured" => true}), do: "large ✗ down"
  defp large(_), do: ""

  defp small(%{"configured" => true, "up" => true} = m),
    do: "small ✓" <> if(m["slots"], do: " #{m["busy"]}/#{m["slots"]}", else: "")

  defp small(%{"configured" => true}), do: "small ✗"
  defp small(_), do: ""

  defp s1(%{"configured" => true, "up" => true}), do: "S1 ✓"
  defp s1(%{"configured" => true}), do: "S1 ✗"
  defp s1(_), do: ""

  defp cpu(%{"cpu" => c, "mem" => m}) do
    "CPU" <>
      opt(c["busy_pct"], &" #{round(&1)}%") <>
      opt(c["load1"], &" load #{&1}") <>
      if(m, do: " RAM #{gb(m["used_bytes"])}/#{gb(m["total_bytes"])} GiB", else: "")
  end

  defp cpu(_), do: ""

  # The last chat prompt against the resident model's context window, when the monitor knows it.
  defp ctx(nil, _monitor), do: ""

  defp ctx(tokens, %{"models" => %{"large" => %{"loaded" => [%{"context" => window} | _]}}})
       when is_integer(window) and window > 0,
       do: " · ctx #{k(tokens)}/#{k(window)}"

  defp ctx(tokens, _monitor), do: " · ctx #{k(tokens)}"

  defp queues(%{"queues" => q}) do
    busy =
      for {tier, %{"in_use" => u, "waiting" => w}} <- Enum.sort(q),
          u + w > 0,
          do: "#{tier} #{u}" <> if(w > 0, do: "+#{w}", else: "")

    if busy == [], do: "", else: "queue " <> Enum.join(busy, " ")
  end

  defp queues(_), do: ""

  defp opt(nil, _fun), do: ""
  defp opt(value, fun), do: fun.(value)

  @gib 1_073_741_824

  defp gb(nil), do: "?"
  defp gb(bytes), do: :erlang.float_to_binary(bytes / @gib, decimals: 1)

  defp k(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp k(n), do: "#{n}"

  defp mmss(s),
    do: "#{div(s, 60)}:#{s |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"

  defp energy(j) when j >= 1000, do: "#{Float.round(j / 1000, 1)} kJ"
  defp energy(j), do: "#{round(j)} J"
end
