defmodule Xeito.Tiers.ModelsCheck do
  @moduledoc """
  Compares each remote tier's model, as OpenRouter serves it to the tier's key, with models.dev's
  public catalogue, at development time (`mix xeito.models.check`).

  - `run/2` fetches both sources: OpenRouter's `/api/v1/models/user` with each tier's key, and
    models.dev's `api.json` (its `openrouter` provider).
  - `compare/3` puts their context window, longest answer, prices, and whether the model takes a
    temperature and tools side by side, names what differs, and warns about tier settings the
    model does not take (a temperature, a reasoning effort).
  - It only reads and reports; nothing in the daemon depends on models.dev.
  """

  alias Xeito.Backends
  alias Xeito.Tiers

  @models_dev "https://models.dev/api.json"

  @type row :: {String.t(), term(), term()}
  @type check :: %{
          optional(:tier) => atom(),
          optional(:model) => String.t(),
          rows: [row()],
          differences: [String.t()],
          warnings: [String.t()],
          missing: String.t() | nil
        }

  @doc """
  The check of every remote tier in `tiers` (`config :xeito, :tiers`). Options: `:url` (the
  models.dev catalogue) and `:plug` (tests).
  """
  @spec run(keyword(), keyword()) :: [check()]
  def run(tiers, opts \\ []) do
    case for({tier, cfg} <- tiers, tier in Tiers.off_box(), cfg[:model] && cfg[:url], do: {tier, cfg}) do
      [] ->
        []

      remote ->
        catalogue = models_dev(opts)

        for {tier, cfg} <- remote do
          served = cfg |> openrouter() |> Enum.find(&(&1["id"] == cfg[:model]))
          listed = get_in(catalogue, ["openrouter", "models", cfg[:model]])
          Map.merge(compare(served, listed, cfg), %{tier: tier, model: cfg[:model]})
        end
    end
  end

  defp openrouter(cfg) do
    case Req.request([method: :get, url: "/v1/models/user"] ++ Backends.req_options(Keyword.put(cfg, :timeout, 15_000))) do
      {:ok, %{status: 200, body: %{"data" => models}}} -> models
      _ -> []
    end
  end

  defp models_dev(opts) do
    req = [method: :get, url: Keyword.get(opts, :url, @models_dev), receive_timeout: 30_000, retry: false]

    case Req.request(req ++ Keyword.take(opts, [:plug])) do
      {:ok, %{status: 200, body: %{} = catalogue}} -> catalogue
      _ -> %{}
    end
  end

  @doc "OpenRouter's entry (`served`) and models.dev's (`listed`) side by side, with the tier's settings (`cfg`)."
  @spec compare(map() | nil, map() | nil, keyword()) :: check()
  def compare(served, listed, cfg) do
    rows = [
      {"context", served_context(served), get_in(listed, ["limit", "context"])},
      {"longest answer", get_in(served, ["top_provider", "max_completion_tokens"]), get_in(listed, ["limit", "output"])},
      {"input $/M", per_million(served, "prompt"), dollars(get_in(listed, ["cost", "input"]))},
      {"output $/M", per_million(served, "completion"), dollars(get_in(listed, ["cost", "output"]))},
      {"temperature", takes?(served, "temperature"), listed && listed["temperature"]},
      {"tools", takes?(served, "tools"), listed && listed["tool_call"]}
    ]

    %{
      rows: rows,
      differences: for({name, a, b} <- rows, served && listed, a != b, do: name),
      warnings: warnings(served, cfg),
      missing: missing(served, listed)
    }
  end

  defp served_context(nil), do: nil
  defp served_context(served), do: get_in(served, ["top_provider", "context_length"]) || served["context_length"]

  defp per_million(served, kind) do
    case get_in(served, ["pricing", kind]) do
      nil -> nil
      price -> price |> Float.parse() |> elem(0) |> Kernel.*(1_000_000) |> Float.round(4)
    end
  end

  defp dollars(nil), do: nil
  defp dollars(amount), do: Float.round(amount * 1.0, 4)

  defp takes?(nil, _parameter), do: nil
  defp takes?(served, parameter), do: parameter in (served["supported_parameters"] || [])

  defp warnings(nil, _cfg), do: []

  defp warnings(served, cfg) do
    for {key, parameter, what} <- [
          {:temperature, "temperature", "a temperature"},
          {:reasoning, "reasoning", "a reasoning effort"}
        ],
        cfg[key] != nil,
        not takes?(served, parameter),
        do: "the tier sets #{what}, which this model does not take"
  end

  defp missing(nil, _listed), do: "OpenRouter for this key"
  defp missing(_served, nil), do: "models.dev"
  defp missing(_served, _listed), do: nil

  @doc "The checks as text: a block per tier, rows that differ marked `≠`, then warnings."
  @spec format([check()]) :: String.t()
  def format([]), do: "no remote tier is configured: nothing to check"

  def format(checks), do: Enum.map_join(checks, "\n\n", &block/1)

  defp block(check) do
    head = "#{check.tier} · #{check.model}" <> if(check.missing, do: "  (not found in #{check.missing})", else: "")

    columns =
      "  #{String.pad_trailing("", 16)}#{String.pad_leading("OpenRouter", 12)}#{String.pad_leading("models.dev", 12)}"

    rows =
      Enum.map(check.rows, fn {name, a, b} ->
        mark = if name in check.differences, do: "≠ ", else: "  "
        "#{mark}#{String.pad_trailing(name, 16)}#{pad(a)}#{pad(b)}"
      end)

    verdict = if check.differences == [] and check.missing == nil, do: ["  no differences"], else: []
    Enum.join([head, columns | rows] ++ verdict ++ Enum.map(check.warnings, &"! #{&1}"), "\n")
  end

  defp pad(value), do: value |> show() |> String.pad_leading(12)

  defp show(nil), do: "—"
  defp show(true), do: "yes"
  defp show(false), do: "no"
  defp show(value), do: to_string(value)
end
