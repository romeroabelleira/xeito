defmodule Xeito.Executables do
  @moduledoc """
  Finds an installed executable, from `config :xeito, :executables` first, then the `PATH`.

  The config maps a name to a path, or to `false` for "not installed"; tests set it.
  """

  @doc "The path of `name`, or `nil` if it is not installed."
  @spec find(String.t()) :: String.t() | nil
  def find(name) do
    case Map.fetch(Application.get_env(:xeito, :executables) || %{}, name) do
      {:ok, path} when is_binary(path) -> path
      {:ok, _not_installed} -> nil
      :error -> System.find_executable(name)
    end
  end
end
