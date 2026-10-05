defmodule Xeito.Effects.MiseEnv do
  @moduledoc """
  Commands run with the tool versions the workspace pins with mise. The daemon starts in its own
  directory, so without this a command in another project would get the daemon's Erlang, Ruby
  or Node, not the project's. When mise is installed and the workspace, or a directory above it,
  has mise configuration (`mise.toml`, `.tool-versions`, …), a command runs as
  `mise exec -- sh -c <command>` there, as it would in the user's shell.

  mise refuses a `mise.toml` it has not been told to trust; that failure is explained with what
  to do (`explain/3`). `.tool-versions` needs no trust.
  """

  alias Xeito.Executables

  @configs ~w(mise.toml .mise.toml mise.local.toml .mise.local.toml .tool-versions mise/config.toml .mise/config.toml .config/mise.toml)

  @doc "The executable and arguments that run `cmd` in `cwd`."
  @spec command(Path.t(), String.t()) :: {String.t(), [String.t()]}
  def command(cwd, cmd) do
    case Executables.find("mise") do
      mise when is_binary(mise) ->
        if configured?(Path.expand(cwd)), do: {mise, ["exec", "--", "sh", "-c", cmd]}, else: plain(cmd)

      nil ->
        plain(cmd)
    end
  end

  defp plain(cmd), do: {"sh", ["-c", cmd]}

  # The directory or one above it holds mise configuration.
  defp configured?(dir) do
    Enum.any?(@configs, &File.regular?(Path.join(dir, &1))) or
      (Path.dirname(dir) != dir and configured?(Path.dirname(dir)))
  end

  @doc "A command's output, with what to do added when mise refused an untrusted configuration."
  @spec explain(String.t(), integer(), Path.t()) :: String.t()
  def explain(output, status, cwd) when status != 0 do
    if output =~ "not trusted",
      do: output <> "\n(xeito: mise does not trust this workspace's configuration: run `mise trust` in #{cwd})\n",
      else: output
  end

  def explain(output, _status, _cwd), do: output
end
