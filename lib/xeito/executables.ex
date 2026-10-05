defmodule Xeito.Executables do
  @moduledoc """
  Where an executable is, if it is installed: `config :xeito, :executables` (a name mapped to a
  path, or to `false` for "not installed"), else the `PATH`. Tests set it, so whether `just` or
  `mise` happens to be installed on the machine running them changes nothing.
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
