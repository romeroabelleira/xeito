defmodule Xeito.Session.Git do
  @moduledoc """
  The workspace's git state for the status bar: branch, uncommitted entries, and commits ahead
  of and behind the upstream. One `git status --porcelain=v2 --branch` call, with a timeout, so a
  huge repository cannot stall the session.
  """

  @timeout 2_000

  @doc """
  `%{branch, dirty, ahead, behind}`, or `nil` outside a repository, on timeout, or when the
  workspace directory no longer exists (git is then not started at all).
  """
  @spec status(Path.t()) :: map() | nil
  def status(cwd) do
    if File.dir?(cwd), do: run_status(cwd)
  end

  defp run_status(cwd) do
    task =
      Task.async(fn ->
        System.cmd("git", ["status", "--porcelain=v2", "--branch"],
          cd: cwd,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> parse(output)
      _ -> nil
    end
  rescue
    # No git binary, or the workspace removed while git starts.
    _ -> nil
  end

  @doc false
  def parse(output) do
    lines = String.split(output, "\n", trim: true)

    Enum.reduce(lines, %{branch: nil, dirty: 0, ahead: 0, behind: 0}, fn
      "# branch.head " <> head, acc ->
        %{acc | branch: head}

      "# branch.ab " <> ab, acc ->
        case Regex.run(~r/\+(\d+) -(\d+)/, ab) do
          [_, a, b] -> %{acc | ahead: String.to_integer(a), behind: String.to_integer(b)}
          nil -> acc
        end

      "#" <> _, acc ->
        acc

      _entry, acc ->
        %{acc | dirty: acc.dirty + 1}
    end)
  end
end
