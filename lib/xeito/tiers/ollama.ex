defmodule Xeito.Tiers.Ollama do
  @moduledoc """
  Model residency for the large tier: which model Ollama has loaded (`/api/ps`), and loading one
  (a *swap*). With one model resident at a time, a swap costs seconds, so the escalation machine
  treats it as a state of its own (`docs/architecture/04-delegation.md#the-cost-of-a-tier-change-is-a-state`).
  """

  alias Xeito.Tiers

  @doc "Whether `model` is resident. Returns `{:ok, boolean}` or an error."
  @spec loaded?(keyword()) :: {:ok, boolean()} | {:error, term()}
  def loaded?(cfg) do
    model = Keyword.fetch!(cfg, :model)

    case Req.request([method: :get, url: "/api/ps"] ++ Tiers.req_options(cfg)) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        {:ok, Enum.any?(models, &(&1["name"] == model or &1["model"] == model))}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Loads `model` (an empty generate request). Returns `{:ok, milliseconds}`."
  @spec load(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load(cfg) do
    started = System.monotonic_time(:millisecond)

    body = %{
      model: Keyword.fetch!(cfg, :model),
      prompt: "",
      keep_alive: Keyword.get(cfg, :keep_alive, "10m")
    }

    opts =
      [method: :post, url: "/api/generate", json: body] ++
        Tiers.req_options(Keyword.put_new(cfg, :timeout, 300_000))

    case Req.request(opts) do
      {:ok, %{status: 200}} -> {:ok, System.monotonic_time(:millisecond) - started}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
