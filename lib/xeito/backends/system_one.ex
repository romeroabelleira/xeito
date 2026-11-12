defmodule Xeito.Backends.SystemOne do
  @moduledoc """
  Decision backend for a Jev-compatible `POST /v1/systemone` server such as `laya-serve`.

  * One `choice` question per decision, named after the type; the answer has a probability per
    option.
  * Every request pins the model (`cfg[:model]`, default `"multilingual"`): the router ignores
    the server-side preference otherwise.
  * `ask/4` is the request other backends of the same API share (`Xeito.Backends.Colibri`):
    `model` goes into the body unless `nil`, and `label` names the result's model from the reply.
  * `probe/2` reads `GET /health`: up, and the loaded models.
  """

  @behaviour Xeito.Backends

  alias Xeito.Backends
  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Type

  @impl true
  def decide(type, input, cfg) do
    model = Keyword.get(cfg, :model, "multilingual")
    ask(type, input, cfg, model: model, label: &("laya-" <> (get_in(&1, ["routing", "model"]) || model)))
  end

  @doc "One `choice` question for `type` on `/v1/systemone`; `opts`: `:model` and `:label`."
  @spec ask(Type.t(), map(), keyword(), keyword()) :: {:ok, Backends.result()} | {:error, term()}
  def ask(type, input, cfg, opts) do
    started = System.monotonic_time(:millisecond)
    body = Prompt.system_one(type, input, opts[:model])
    name = type.name

    case Req.request([method: :post, url: "/v1/systemone", json: body] ++ Backends.req_options(cfg)) do
      {:ok, %{status: 200, body: %{"answers" => %{^name => answer}} = resp}} ->
        probs = Map.get(answer, "probabilities") || %{answer["choice"] => 1.0}
        cost = %{tokens_in: get_in(resp, ["usage", "input_tokens"]) || 0, tokens_out: 0}
        Backends.result(type, probs, Keyword.fetch!(opts, :label).(resp), started, cost)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def probe(cfg, opts) do
    case Backends.get(cfg, "/health", Keyword.fetch!(opts, :timeout)) do
      {:ok, %{"status" => "ok"} = body} -> %{up: true, loaded: body["loaded"] || []}
      _ -> %{up: false}
    end
  end
end
