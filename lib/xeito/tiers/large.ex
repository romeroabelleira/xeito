defmodule Xeito.Tiers.Large do
  @moduledoc """
  Large tier: Ollama `/api/chat` with the decision's JSON Schema as `format` and `logprobs`.

  The answer is generated under the grammar at temperature 0. Its confidence comes from the
  `top_logprobs` at the first token of the value, renormalised over the options
  (`Xeito.Decision.Scoring.one_step/2`). If that position cannot be found, the chosen value
  gets the product of its own token probabilities.
  """

  @behaviour Xeito.Tiers

  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Scoring
  alias Xeito.Decision.Type
  alias Xeito.Tiers

  @impl true
  def decide(type, input, cfg) do
    started = System.monotonic_time(:millisecond)
    model = Keyword.fetch!(cfg, :model)

    body = %{
      model: model,
      stream: false,
      think: false,
      messages: Prompt.messages(type, input),
      format: Prompt.json_schema(type),
      options: %{temperature: 0},
      logprobs: true,
      top_logprobs: Keyword.get(cfg, :top_logprobs, 10),
      keep_alive: Keyword.get(cfg, :keep_alive, "10m")
    }

    opts =
      [method: :post, url: "/api/chat", json: body] ++
        Tiers.req_options(Keyword.put_new(cfg, :timeout, 300_000))

    case Req.request(opts) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}} = resp}} ->
        probs = probabilities(content, Map.get(resp, "logprobs") || [], type)
        cost = %{tokens_in: resp["prompt_eval_count"] || 0, tokens_out: resp["eval_count"] || 0}
        Tiers.result(type, probs, model, started, cost)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def probabilities(content, logprobs, type) do
    options = type |> Type.values() |> Enum.map(&Atom.to_string/1)

    with {:ok, %{"value" => value}} <- JSON.decode(content),
         [_ | _] = at_value <- drop_to_value(logprobs) do
      tops = Enum.map(hd(at_value)["top_logprobs"] || [], &{&1["token"], &1["logprob"]})

      case Scoring.one_step(tops, options) do
        empty when map_size(empty) == 0 -> own_probability(value, at_value)
        probs -> probs
      end
    else
      {:ok, _} -> %{}
      {:error, _} -> %{}
      [] -> chosen_only(content)
    end
  end

  # Tokens from the first one after `"value": "` onwards.
  defp drop_to_value(logprobs) do
    {_, rest} =
      Enum.reduce_while(logprobs, {"", logprobs}, fn token, {text, [_ | tail]} ->
        text = text <> token["token"]

        if text |> String.replace(" ", "") |> String.ends_with?(~s("value":")),
          do: {:halt, {text, tail}},
          else: {:cont, {text, tail}}
      end)

    rest
  end

  defp own_probability(value, at_value) do
    logprob =
      at_value
      |> Enum.take_while(&(not String.contains?(&1["token"], "\"")))
      |> Enum.map(& &1["logprob"])
      |> Enum.sum()

    %{value => :math.exp(logprob)}
  end

  defp chosen_only(content) do
    case JSON.decode(content) do
      {:ok, %{"value" => value}} -> %{value => 1.0}
      _ -> %{}
    end
  end
end
