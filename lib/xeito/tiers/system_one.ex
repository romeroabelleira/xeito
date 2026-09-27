defmodule Xeito.Tiers.SystemOne do
  @moduledoc """
  System One tier: a Jev-compatible `POST /v1/systemone` backend such as `laya-serve`.

  One `choice` question per decision, named after the type. The backend returns a probability
  for every option. The model is pinned on every request (`cfg[:model]`, default
  `"multilingual"`), because Laya's router otherwise ignores the server-side preference (bench 0).
  """

  @behaviour Xeito.Tiers

  alias Xeito.Decision.Prompt
  alias Xeito.Tiers

  @impl true
  def decide(type, input, cfg) do
    started = System.monotonic_time(:millisecond)
    model = Keyword.get(cfg, :model, "multilingual")
    body = Prompt.system_one(type, input, model)

    name = type.name

    case Req.request([method: :post, url: "/v1/systemone", json: body] ++ Tiers.req_options(cfg)) do
      {:ok, %{status: 200, body: %{"answers" => %{^name => answer}} = resp}} ->
        probs = Map.get(answer, "probabilities") || %{answer["choice"] => 1.0}
        routed = get_in(resp, ["routing", "model"]) || model
        cost = %{tokens_in: get_in(resp, ["usage", "input_tokens"]) || 0, tokens_out: 0}
        Tiers.result(type, probs, "laya-" <> routed, started, cost)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
