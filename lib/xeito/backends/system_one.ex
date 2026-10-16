defmodule Xeito.Backends.SystemOne do
  @moduledoc """
  Decision backend for a Jev-compatible `POST /v1/systemone` server such as `laya-serve`.

  * One `choice` question per decision, named after the type; the answer has a probability per
    option.
  * Every request pins the model (`cfg[:model]`, default `"multilingual"`): the router ignores
    the server-side preference otherwise.
  """

  @behaviour Xeito.Backends

  alias Xeito.Backends
  alias Xeito.Decision.Prompt

  @impl true
  def decide(type, input, cfg) do
    started = System.monotonic_time(:millisecond)
    model = Keyword.get(cfg, :model, "multilingual")
    body = Prompt.system_one(type, input, model)

    name = type.name

    case Req.request([method: :post, url: "/v1/systemone", json: body] ++ Backends.req_options(cfg)) do
      {:ok, %{status: 200, body: %{"answers" => %{^name => answer}} = resp}} ->
        probs = Map.get(answer, "probabilities") || %{answer["choice"] => 1.0}
        routed = get_in(resp, ["routing", "model"]) || model
        cost = %{tokens_in: get_in(resp, ["usage", "input_tokens"]) || 0, tokens_out: 0}
        Backends.result(type, probs, "laya-" <> routed, started, cost)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
