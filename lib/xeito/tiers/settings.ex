defmodule Xeito.Tiers.Settings do
  @moduledoc """
  Reads the tiers' configuration from `XEITO_*` environment variables (used by `config/runtime.exs`).

  Per tier, under the prefix `XEITO_<TIER>_` (e.g. `XEITO_LOCAL_MODEL`):

    * `BACKEND` — the API it speaks (`Xeito.Backends`); default: the tier's (`Xeito.Tiers`)
    * `URL` — default: OpenRouter's for an OpenRouter tier, none otherwise
    * `MODEL`, `KEY_FILE` (a file holding the API key)
    * `CONTEXT` (Ollama `num_ctx`), `KEEP_ALIVE` (Ollama)
    * `PROVIDERS` (OpenRouter: comma list to pin), `ZDR` (OpenRouter: `false` allows endpoints
      that retain prompts; default on), `REASONING` (OpenRouter chat effort, e.g. `low`)

  Not per tier (`app_env/1`): `XEITO_CHAT_TIER` (default chat tier) and `XEITO_MAX_USD_PER_RUN`
  (off-box spend limit per run, `Xeito.Policy`).

  A local tier is configured by its URL; a remote tier only when URL, model and key file are all
  set. An unconfigured tier is left out and never reached. Bad values raise `ArgumentError`.
  """

  alias Xeito.Backends
  alias Xeito.Tiers

  @openrouter_url "https://openrouter.ai/api"

  @doc "The `config :xeito, :tiers` keyword list for an environment (`System.get_env/0`)."
  @spec from_env(%{String.t() => String.t()}, (String.t() -> String.t())) :: keyword()
  def from_env(env, read_key \\ &read_key/1) do
    for tier <- Tiers.all(), cfg = tier(tier, setting(env, tier), read_key), cfg != nil, do: {tier, cfg}
  end

  defp setting(env, tier) do
    prefix = "XEITO_" <> String.upcase(Atom.to_string(tier)) <> "_"
    fn name -> {prefix <> name, Map.get(env, prefix <> name)} end
  end

  defp tier(tier, get, read_key) do
    backend = backend(tier, get.("BACKEND"))
    url = value(get.("URL")) || default_url(backend)

    if configured?(tier, url, value(get.("MODEL")), value(get.("KEY_FILE"))) do
      Enum.reject(
        [
          backend: backend,
          url: url,
          model: value(get.("MODEL")),
          api_key: key(value(get.("KEY_FILE")), read_key),
          context: context(get.("CONTEXT")),
          keep_alive: value(get.("KEEP_ALIVE")),
          providers: providers(value(get.("PROVIDERS"))),
          zdr: zdr(value(get.("ZDR"))),
          reasoning: value(get.("REASONING"))
        ],
        fn {_key, v} -> v == nil end
      )
    end
  end

  defp value({_name, value}), do: value

  @doc "Settings that are not per tier, as `config :xeito` keys; only those set."
  @spec app_env(%{String.t() => String.t()}) :: keyword()
  def app_env(env) do
    Enum.reject(
      [
        chat_tier: chat_tier(env["XEITO_CHAT_TIER"]),
        policy: max_usd(env["XEITO_MAX_USD_PER_RUN"])
      ],
      fn {_key, v} -> v == nil end
    )
  end

  defp chat_tier(nil), do: nil

  defp chat_tier(name) do
    case Enum.find(Tiers.all(), &(Atom.to_string(&1) == name)) do
      nil ->
        raise ArgumentError, "XEITO_CHAT_TIER: unknown tier #{inspect(name)} (one of: #{Enum.join(Tiers.all(), ", ")})"

      tier ->
        tier
    end
  end

  defp max_usd(nil), do: nil

  defp max_usd(value) do
    case Float.parse(value) do
      {usd, ""} when usd >= 0 -> [max_usd_per_run: usd]
      _ -> raise ArgumentError, "XEITO_MAX_USD_PER_RUN: not an amount in USD: #{inspect(value)}"
    end
  end

  defp configured?(tier, url, model, key_file) do
    if tier in Tiers.off_box(), do: url != nil and model != nil and key_file != nil, else: url != nil
  end

  defp backend(tier, {_name, nil}), do: Tiers.backend(tier, [])

  defp backend(_tier, {name, value}) do
    case Enum.find(Backends.names(), &(Atom.to_string(&1) == value)) do
      nil ->
        raise ArgumentError, "#{name}: unknown backend #{inspect(value)} (one of: #{Enum.join(Backends.names(), ", ")})"

      backend ->
        backend
    end
  end

  defp default_url(:openrouter), do: @openrouter_url
  defp default_url(_backend), do: nil

  defp key(nil, _read_key), do: nil
  defp key(path, read_key), do: read_key.(path)

  defp context({_name, nil}), do: nil

  defp context({name, value}) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> raise ArgumentError, "#{name}: not a whole number: #{inspect(value)}"
    end
  end

  defp providers(nil), do: nil
  defp providers(list), do: String.split(list, ",", trim: true)

  defp zdr(nil), do: nil
  defp zdr(value), do: value != "false"

  defp read_key(path), do: path |> Path.expand() |> File.read!() |> String.trim()
end
