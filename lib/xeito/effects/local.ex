defmodule Xeito.Effects.Local do
  @moduledoc """
  Executes effects on the local machine, confined to the effect's workspace (`:cwd`).

    * `bash` runs `sh -c` in the workspace. Output is merged (stderr into stdout) and
      truncated to `opts[:max_output]` bytes (default 64 KiB). On timeout the result is
      `exit_status: 124`.
    * `read` / `write` resolve paths relative to the workspace and refuse anything outside it.
    * `decide` runs `Xeito.Decider.decide/3` (rules, then the model tiers). `opts[:decider]`
      passes decider options, and `opts[:decide]` (`fun(effect) -> value`) overrides it (tests).
  """

  @behaviour Xeito.Effects.Runner

  alias Xeito.Effect

  @max_output 65_536

  @impl true
  def run(%Effect{kind: :bash, args: args}, opts) do
    cwd = workspace!(args)

    task =
      Task.async(fn -> System.cmd("sh", ["-c", args.cmd], cd: cwd, stderr_to_stdout: true) end)

    case Task.yield(task, args.timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} -> %{exit_status: status, output: truncate(output, opts)}
      nil -> %{exit_status: 124, output: "timed out after #{args.timeout} ms"}
    end
  end

  def run(%Effect{kind: :read, args: args}, _opts) do
    with {:ok, path} <- resolve(args),
         {:ok, content} <- File.read(path) do
      %{ok: true, content: content}
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  def run(%Effect{kind: :write, args: args}, _opts) do
    with {:ok, path} <- resolve(args),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, args.content) do
      %{ok: true}
    else
      {:error, reason} -> %{ok: false, error: reason}
    end
  end

  def run(%Effect{kind: :decide, args: args} = effect, opts) do
    case opts[:decide] do
      nil ->
        decision =
          Xeito.Decider.decide(args.decision, args.input, Keyword.get(opts, :decider, []))

        %{value: decision.value, decision: Xeito.Decision.to_map(decision)}

      fun ->
        %{value: fun.(effect)}
    end
  end

  @doc "Resolves `args.path` inside the workspace, or returns `{:error, :outside_workspace}`."
  @spec resolve(map()) :: {:ok, Path.t()} | {:error, :outside_workspace}
  def resolve(%{path: path} = args) do
    root = workspace!(args)
    full = Path.expand(path, root)

    if full == root or String.starts_with?(full, root <> "/"),
      do: {:ok, full},
      else: {:error, :outside_workspace}
  end

  defp workspace!(%{cwd: cwd}) when is_binary(cwd), do: Path.expand(cwd)
  defp workspace!(_), do: raise(ArgumentError, "effect has no workspace (:cwd)")

  defp truncate(output, opts) do
    max = Keyword.get(opts, :max_output, @max_output)

    if byte_size(output) > max,
      do: binary_part(output, byte_size(output) - max, max),
      else: output
  end
end
