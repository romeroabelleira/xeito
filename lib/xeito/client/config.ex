defmodule Xeito.Client.Config do
  @moduledoc """
  Per-user client preferences, as JSON: `$XEITO_TUI_CONFIG`, else
  `$XDG_CONFIG_HOME/xeito/tui.json`, else `~/.config/xeito/tui.json`.

      {"status_bar": {"visible": true, "hidden": ["cpu", "queue"]}}

  Preferences belong to the client, not the daemon: they change how things are shown, never
  what runs. A missing or unreadable file means the defaults.
  """

  @defaults %{"status_bar" => %{"visible" => true, "hidden" => []}}

  @doc "The preferences file path."
  @spec path() :: Path.t()
  def path do
    System.get_env("XEITO_TUI_CONFIG") ||
      Path.join([
        System.get_env("XDG_CONFIG_HOME") || Path.expand("~/.config"),
        "xeito",
        "tui.json"
      ])
  end

  @doc "The preferences, merged over the defaults."
  @spec load(Path.t()) :: map()
  def load(file \\ path()) do
    with {:ok, text} <- File.read(file),
         {:ok, %{} = prefs} <- JSON.decode(text) do
      deep_merge(@defaults, prefs)
    else
      _ -> @defaults
    end
  end

  @doc "Saves the preferences (creating the directory). Errors are returned, not raised."
  @spec save(map(), Path.t()) :: :ok | {:error, term()}
  def save(prefs, file \\ path()) do
    with :ok <- File.mkdir_p(Path.dirname(file)) do
      File.write(file, JSON.encode!(prefs) <> "\n")
    end
  end

  defp deep_merge(a, b) when is_map(a) and is_map(b),
    do: Map.merge(a, b, fn _k, x, y -> deep_merge(x, y) end)

  defp deep_merge(_a, b), do: b
end
