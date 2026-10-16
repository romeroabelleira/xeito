defmodule Xeito.Effects.MiseEnv do
  @moduledoc """
  Wraps a shell command so it runs with the tool versions the workspace pins with mise.

  * When mise is installed and the workspace or a parent has mise configuration, the command is
    `mise exec -- sh -c <command>`; otherwise `sh -c <command>`.
  * `explain/3` adds a hint when mise refused an untrusted `mise.toml`.
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
