defmodule Xeito.Backends.Ollama do
  @moduledoc """
  Ollama backend: decisions through `/api/chat` with the decision's JSON Schema as `format` and
  `logprobs`, and model residency.

  The answer is generated under the grammar at temperature 0. Its confidence comes from the
  `top_logprobs` at the first token of the value, renormalised over the options
  (`Xeito.Decision.Scoring.one_step/2`). If that position cannot be found, the chosen value
  gets the product of its own token probabilities.

  Residency: which model Ollama has loaded (`/api/ps`), and loading one (a *swap*). With one
  model resident at a time, a swap costs seconds, so the escalation machine treats it as a state
  of its own (`docs/architecture/04-delegation.md#the-cost-of-a-tier-change-is-a-state`).
  """

  @behaviour Xeito.Backends

  alias Xeito.Backends
  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Scoring
  alias Xeito.Decision.Type

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
      options: Backends.context_options(cfg, %{temperature: 0}),
      logprobs: true,
      top_logprobs: Keyword.get(cfg, :top_logprobs, 10),
      keep_alive: Keyword.get(cfg, :keep_alive, "10m")
    }

    opts =
      [method: :post, url: "/api/chat", json: body] ++
        Backends.req_options(Keyword.put_new(cfg, :timeout, 300_000))

    case Req.request(opts) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}} = resp}} ->
        probs = probabilities(content, Map.get(resp, "logprobs") || [], type)
        cost = %{tokens_in: resp["prompt_eval_count"] || 0, tokens_out: resp["eval_count"] || 0}
        Backends.result(type, probs, model, started, cost)

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Whether `model` is resident. Returns `{:ok, boolean}` or an error."
  @spec loaded?(keyword()) :: {:ok, boolean()} | {:error, term()}
  def loaded?(cfg) do
    model = Keyword.fetch!(cfg, :model)

    case Req.request([method: :get, url: "/api/ps"] ++ Backends.req_options(cfg)) do
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
      options: Backends.context_options(cfg, %{}),
      keep_alive: Keyword.get(cfg, :keep_alive, "10m")
    }

    opts =
      [method: :post, url: "/api/generate", json: body] ++
        Backends.req_options(Keyword.put_new(cfg, :timeout, 300_000))

    case Req.request(opts) do
      {:ok, %{status: 200}} -> {:ok, System.monotonic_time(:millisecond) - started}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def probabilities(content, logprobs, type) do
    options = type |> Type.values() |> Enum.map(&Atom.to_string/1)

    with {:ok, %{"value" => value}} <- JSON.decode(content),
         [_ | _] = at_value <- drop_to_value(logprobs) do
      at_value |> tops() |> Scoring.one_step(options) |> or_own(value, at_value)
    else
      {:ok, _} -> %{}
      {:error, _} -> %{}
      [] -> chosen_only(content)
    end
  end

  defp tops([first | _]), do: Enum.map(first["top_logprobs"] || [], &{&1["token"], &1["logprob"]})

  # No usable alternatives at the value: the chosen value's own probability.
  defp or_own(probs, value, at_value) when map_size(probs) == 0, do: own_probability(value, at_value)
  defp or_own(probs, _value, _at_value), do: probs

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
