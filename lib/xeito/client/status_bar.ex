defmodule Xeito.Client.StatusBar do
  @moduledoc """
  The TUI's toggleable status bar, as pure functions: usage is counted from the daemon events a
  client already receives, and hardware and model status come from `Xeito.Monitor` snapshots.

      GPU 18.5/24.0 GiB 97% 290 W 61°C │ large qwen3.6:27b unload 4:12 │ small ✓ 1/4 │ S1 ✓ │ CPU 23% load 1.2 RAM 17.1/62.0 GiB
      large 12 · small 3 · rule 9 · human 1 │ 18.4k→1.2k tok · ctx 3.2k/81.9k │ triage large 512 ms │ reply 2.1 s (first 0.4 s) │ det 45% │ $0.0000 · ~2.1 kJ │ queue large 1+2

  * **Calls** per actor: decisions (`decision_made`, `intent`) and chat turns (`chat`).
  * **Tokens** in → out over the session, and **ctx**: the prompt size of the last chat turn
    against the resident model's context window, i.e. how full the context is.
  * **decision** and **reply**: the latest decision (type, who decided, how long it took) and
    the latest model reply (total time, and time to its first chunk).
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
          last_decision: map() | nil,
          last_reply: map() | nil,
          usd: float(),
          joules: float(),
          det: {non_neg_integer(), non_neg_integer()}
        }

  @doc "Empty usage counters."
  @spec new() :: usage()
  def new,
    do: %{
      calls: %{},
      tokens_in: 0,
      tokens_out: 0,
      ctx: nil,
      usd: 0.0,
      joules: 0.0,
      det: {0, 0},
      last_decision: nil,
      last_reply: nil
    }

  @doc "Counts one daemon event (string keys, as decoded from the API)."
  @spec count(usage(), map()) :: usage()
  def count(usage, %{"event" => event, "run" => run} = e) when is_binary(run) do
    if internal?(run), do: usage, else: count_event(usage, event, e)
  end

  def count(usage, %{"event" => event} = e), do: count_event(usage, event, e)

  defp count_event(usage, type, %{"attrs" => a}) when type in ["decision_made", "intent"] do
    decision = %{
      type: if(type == "intent", do: "intent", else: short_type(a["decision_type"])),
      actor: to_string(a["actor"] || "none"),
      ms: a["latency_ms"]
    }

    usage
    |> call(decision.actor)
    |> add_cost(a)
    |> Map.put(:last_decision, decision)
  end

  defp count_event(usage, "effect_completed", %{"attrs" => %{"kind" => kind, "result" => r}})
       when kind in ["chat", :chat] and is_map(r) do
    usage
    |> call("chat")
    |> add_cost(r)
    |> Map.put(:ctx, r["tokens_in"] || usage.ctx)
    |> Map.put(:last_reply, %{ms: r["latency_ms"], first_ms: r["first_token_ms"]})
  end

  defp count_event(usage, "transition", %{"attrs" => %{"actor" => actor}}) do
    {code, total} = usage.det
    code = if to_string(actor) in ["code", "rule"], do: code + 1, else: code
    %{usage | det: {code, total + 1}}
  end

  defp count_event(usage, _type, _event), do: usage

  defp short_type(nil), do: "decision"

  defp short_type(type),
    do: type |> to_string() |> String.split(".") |> List.last() |> Macro.underscore()

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

  # Segment → line. Order within a line is fixed; any segment can be hidden.
  @segments [
    gpu: 1,
    models: 1,
    cpu: 1,
    git: 1,
    calls: 2,
    tokens: 2,
    decision: 2,
    reply: 2,
    det: 2,
    cost: 2,
    budget: 2,
    queue: 2
  ]

  @doc "The segment names, in display order."
  @spec segments() :: [String.t()]
  def segments, do: Enum.map(@segments, fn {name, _} -> Atom.to_string(name) end)

  @doc """
  The bar's lines (empty lines are dropped): machine, models and workspace from a monitor
  snapshot and a session `workspace` event (either may be `nil`), then usage. `hidden` lists
  segment names not to show.
  """
  @spec lines(usage(), map() | nil, map() | nil, [String.t()]) :: [String.t()]
  def lines(usage, monitor, workspace \\ nil, hidden \\ []) do
    parts =
      for {name, line} <- @segments,
          Atom.to_string(name) not in hidden,
          do: {line, segment(name, usage, monitor, workspace)}

    for line <- [1, 2],
        text = parts |> Enum.filter(&(elem(&1, 0) == line)) |> Enum.map(&elem(&1, 1)) |> join(),
        text != "",
        do: text
  end

  defp join(texts), do: texts |> Enum.reject(&(&1 == "")) |> Enum.join(" │ ")

  defp segment(:gpu, _u, nil, _w), do: "status: waiting for the daemon's monitor…"
  defp segment(:gpu, _u, m, _w), do: gpu(m["system"]["gpus"])
  defp segment(:models, _u, nil, _w), do: ""

  defp segment(:models, _u, %{"models" => models}, _w),
    do: join([large(models["large"]), small(models["small"]), s1(models["system_one"])])

  defp segment(:cpu, _u, nil, _w), do: ""
  defp segment(:cpu, _u, m, _w), do: cpu(m["system"])
  defp segment(:git, _u, _m, w), do: git(w && w["git"])
  defp segment(:calls, u, _m, _w), do: calls(u)
  defp segment(:tokens, u, m, _w), do: "#{k(u.tokens_in)}→#{k(u.tokens_out)} tok" <> ctx(u.ctx, m)
  defp segment(:det, u, _m, _w), do: det(u.det)
  defp segment(:decision, u, _m, _w), do: last_decision(u.last_decision)
  defp segment(:reply, u, _m, _w), do: last_reply(u.last_reply)

  defp segment(:cost, u, _m, _w),
    do: "$#{:erlang.float_to_binary(u.usd * 1.0, decimals: 4)} · ~#{energy(u.joules)}"

  defp segment(:budget, _u, _m, w), do: budget(w && w["budget"])
  defp segment(:queue, _u, m, _w), do: queues(m)

  @doc false
  def system_line(monitor, workspace \\ nil),
    do: lines(new(), monitor, workspace, ~w(calls tokens det cost budget queue)) |> List.first("")

  @doc false
  def usage_line(usage, monitor, workspace \\ nil),
    do: lines(usage, monitor, workspace, ~w(gpu models cpu git)) |> List.first("")

  defp calls(usage) do
    case usage.calls |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {a, n} -> "#{a} #{n}" end) do
      [] -> "no model calls yet"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp last_decision(%{ms: ms} = d) when is_number(ms),
    do: "#{d.type} #{d.actor} #{duration(ms)}"

  defp last_decision(_), do: ""

  defp last_reply(%{ms: ms, first_ms: first}) when is_number(ms),
    do:
      "reply #{duration(ms)}" <> if(is_number(first), do: " (first #{duration(first)})", else: "")

  defp last_reply(_), do: ""

  defp duration(ms) when ms < 1000, do: "#{round(ms)} ms"
  defp duration(ms), do: "#{:erlang.float_to_binary(ms / 1000, decimals: 1)} s"

  defp det({_code, 0}), do: "det -"
  defp det({code, total}), do: "det #{round(100 * code / total)}%"

  defp git(nil), do: ""

  defp git(%{"branch" => branch, "dirty" => dirty} = g) do
    state = if dirty == 0, do: "clean", else: "#{dirty} changed"

    ab =
      if(g["ahead"] > 0, do: " ↑#{g["ahead"]}", else: "") <>
        if(g["behind"] > 0, do: " ↓#{g["behind"]}", else: "")

    "git #{branch} #{state}#{ab}"
  end

  defp budget(nil), do: ""
  defp budget(%{"off_box" => false}), do: "off-box off"

  defp budget(%{"max_usd_per_run" => max, "spent_usd" => spent}) do
    left = max(max - spent, 0)

    "budget $#{:erlang.float_to_binary(left * 1.0, decimals: 2)}/#{:erlang.float_to_binary(max * 1.0, decimals: 2)}"
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
