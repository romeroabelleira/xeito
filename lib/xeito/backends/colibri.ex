defmodule Xeito.Backends.Colibri do
  @moduledoc """
  Colibri backend: decisions through `POST /v1/systemone` and chat through OpenAI's chat completions, on one model per server.

  A tier needs a `url` (the server's root). `model` must be the id the server serves
  (`GET /v1/models`); the server answers 404 for another, so there is no residency and no swap.

  Decisions (`decide/3`): one `choice` question (`Xeito.Backends.SystemOne.ask/4`), which the
  served chat model answers by scoring the options, or a decision model natively. The result's
  model is `colibri:<the model the reply names>`.

  Chat (`chat/4`, `body/3`): `Xeito.Chat.OpenAI`'s request, plus `context_compaction: "off"`
  (Xeito fits and summarises the conversation itself) and `enable_thinking` when `think:` is set.
  `max_tokens` is sent only when the tier sets one; without it an answer may run to the end of
  the server's context.

  `probe/2` reads `GET /health` and `GET /v1/models`:

    * `up`, and `status` when the server answers but its engine does not (`"restarting"`)
    * `loaded`: the served model with the context the server was started with
    * `mismatch: true` when the tier's `model` is not the served one

  Nothing is billed (`Xeito.Backends.spend/1` is `:none`).
  """

  @behaviour Xeito.Backends

  alias Xeito.Backends
  alias Xeito.Backends.SystemOne
  alias Xeito.Chat.OpenAI

  @impl true
  def decide(type, input, cfg) do
    SystemOne.ask(type, input, cfg, model: cfg[:model], label: &("colibri:" <> (&1["model"] || cfg[:model] || "served")))
  end

  @impl true
  def chat(messages, tools, cfg, on_delta), do: OpenAI.request(body(messages, tools, cfg), cfg, on_delta, name: :colibri)

  @doc "The chat request: OpenAI's, with Colibri's extensions."
  @spec body([Xeito.Chat.Message.t()], [map()], keyword()) :: map()
  def body(messages, tools, cfg) do
    messages
    |> OpenAI.body(tools, cfg)
    |> Map.put(:context_compaction, "off")
    |> OpenAI.put_if(:enable_thinking, true, cfg[:think] == true)
  end

  @impl true
  def probe(cfg, opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    case Backends.get(cfg, "/health", timeout) do
      {:ok, %{"status" => "ok"}} -> served(cfg, Backends.get(cfg, "/v1/models", timeout))
      {:error, {:http, 503}} -> %{up: false, loaded: [], status: "restarting"}
      _ -> %{up: false, loaded: []}
    end
  end

  defp served(cfg, {:ok, %{"data" => models}}) do
    loaded = Enum.map(models, &%{name: &1["id"], context: &1["context_length"]})
    %{up: true, loaded: loaded, mismatch: cfg[:model] != nil and cfg[:model] not in Enum.map(loaded, & &1.name)}
  end

  defp served(_cfg, _error), do: %{up: true, loaded: [], mismatch: false}
end
