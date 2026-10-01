defmodule Xeito.Tiers.Small do
  @moduledoc """
  Small generative tier: a grammar-free *scoring* call against llama-server.

  Instead of generating the answer, the tier renders the chat prompt (`/apply-template`),
  prefills the assistant turn up to the value (`{"value": "`), and asks for exactly one token
  with `n_probs` alternatives (`/completion`, `n_predict: 1`). The top tokens are mapped to
  the options they start, and the mass is renormalised (`Xeito.Decision.Scoring`). If a token
  could start several options, the prefix is extended with that token and scored again.

  One forward pass, no generated text, and a real distribution over the options. The static
  part of the prompt is cached by the server (`cache_prompt`).
  """

  @behaviour Xeito.Tiers

  alias Xeito.Decision.Prompt
  alias Xeito.Decision.Scoring
  alias Xeito.Decision.Type
  alias Xeito.Tiers

  @prefill ~s({"value": ")
  @max_depth 4

  @impl true
  def decide(type, input, cfg) do
    started = System.monotonic_time(:millisecond)

    with {:ok, prompt} <- template(type, input, cfg),
         {:ok, probs} <- score(prompt <> @prefill, options(type), cfg, 0) do
      # One forward pass over the prompt; no generated tokens are kept (~4 bytes per token).
      cost = %{tokens_in: div(byte_size(prompt), 4), tokens_out: 0}
      Tiers.result(type, probs, Keyword.get(cfg, :model, "small"), started, cost)
    end
  end

  defp options(type), do: type |> Type.values() |> Enum.map(&Atom.to_string/1)

  defp template(type, input, cfg) do
    body = %{
      messages: Prompt.messages(type, input),
      chat_template_kwargs: %{enable_thinking: false}
    }

    case post("/apply-template", body, cfg) do
      {:ok, %{"prompt" => prompt}} -> {:ok, prompt}
      other -> error(other)
    end
  end

  # Returns probabilities for the full option strings in `options`, given `prefix`.
  defp score(prefix, options, cfg, depth) do
    with {:ok, tops} <- next_token(prefix, cfg) do
      %{probs: probs, ambiguous: ambiguous} = Scoring.assign(tops, options)
      resolve(prefix, probs, ambiguous, cfg, depth)
    end
  end

  defp resolve(_prefix, probs, [], _cfg, _depth), do: {:ok, Scoring.normalize(probs)}

  defp resolve(prefix, probs, ambiguous, cfg, depth) when depth < @max_depth do
    ambiguous
    |> Enum.reduce_while({:ok, probs}, fn group, {:ok, acc} ->
      resolve_group(prefix, group, acc, cfg, depth)
    end)
    |> case do
      {:ok, merged} -> {:ok, Scoring.normalize(merged)}
      error -> error
    end
  end

  defp resolve(_prefix, probs, ambiguous, _cfg, _depth) do
    {:ok, ambiguous |> Enum.reduce(probs, &split_evenly/2) |> Scoring.normalize()}
  end

  # Continues after the ambiguous `token`; the options' remaining suffixes decide the split.
  defp resolve_group(prefix, %{token: token, mass: mass, options: opts}, acc, cfg, depth) do
    suffixes = Map.new(opts, &{suffix_after(&1, token), &1})

    case score(prefix <> token, Map.keys(suffixes), cfg, depth + 1) do
      {:ok, sub} ->
        {:cont, {:ok, Enum.reduce(sub, acc, fn {s, p}, a -> add(a, suffixes[s], mass * p) end)}}

      error ->
        {:halt, error}
    end
  end

  defp add(acc, option, mass), do: Map.update(acc, option, mass, &(&1 + mass))

  defp split_evenly(%{mass: mass, options: opts}, acc) do
    Enum.reduce(opts, acc, fn o, a ->
      Map.update(a, o, mass / length(opts), &(&1 + mass / length(opts)))
    end)
  end

  defp suffix_after(option, token) do
    t = String.trim_leading(token)

    if String.starts_with?(option, t),
      do: binary_part(option, byte_size(t), byte_size(option) - byte_size(t)),
      else: ""
  end

  defp next_token(prompt, cfg) do
    body = %{
      prompt: prompt,
      n_predict: 1,
      n_probs: Keyword.get(cfg, :n_probs, 50),
      temperature: 0,
      cache_prompt: true
    }

    case post("/completion", body, cfg) do
      {:ok, %{"completion_probabilities" => [%{"top_logprobs" => tops} | _]}} ->
        {:ok, Enum.map(tops, &{&1["token"], &1["logprob"]})}

      other ->
        error(other)
    end
  end

  defp post(path, body, cfg) do
    case Req.request([method: :post, url: path, json: body] ++ Tiers.req_options(cfg)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error({:error, _} = e), do: e
  defp error(other), do: {:error, {:unexpected_response, other}}
end
