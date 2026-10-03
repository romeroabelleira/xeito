defmodule Xeito.Tiers.Settings do
  @moduledoc """
  Reads the tiers' configuration from the environment (`config/runtime.exs`), so no deployment
  detail lives in the repository.

  Every tier reads the same settings under its own prefix, `XEITO_<TIER>_`, for example
  `XEITO_LOCAL_MODEL` or `XEITO_REMOTE_FRONTIER_KEY_FILE`:

    * `BACKEND` — the API it speaks (`Xeito.Backends`); default: the tier's (`Xeito.Tiers`)
    * `URL` — default: OpenRouter's for an OpenRouter tier, none otherwise
    * `MODEL`, `KEY_FILE` (a file holding the API key)
    * `CONTEXT` (Ollama: the context window, sent as `num_ctx`), `KEEP_ALIVE` (Ollama)
    * `PROVIDERS` (OpenRouter: a comma list to pin), `ZDR` (OpenRouter: `false` to allow
      endpoints that retain prompts; default on)

  A local tier is configured by its URL. A remote tier is opt-in: it is configured only when its
  URL, its model and its key file are all set, so one OpenRouter key does not switch on both
  remote tiers. An unconfigured tier is left out, and the escalation never reaches it.
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
          zdr: zdr(value(get.("ZDR")))
        ],
        fn {_key, v} -> v == nil end
      )
    end
  end

  defp value({_name, value}), do: value

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
