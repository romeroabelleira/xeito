defmodule Xeito.Session.UndoCommand do
  @moduledoc """
  The `/undo [n]` and `/redo [n]` commands: reverting the session's last n file changes, or putting them back.

  `run/3` goes through `Xeito.Undo`. On success it logs a `step_undone` or `step_redone` event
  per step in the session's own stream (against the effect reverted), adds a note in the user's
  voice to the history so the model does not assume the files are as it left them, and emits a
  notice listing the steps. On failure it emits an error and changes nothing.
  """

  alias Xeito.Log
  alias Xeito.Session
  alias Xeito.Session.Notify
  alias Xeito.Undo

  @doc "Runs `/undo` or `/redo` (`name`) with its argument, a step count (empty for one)."
  @spec run(String.t(), String.t(), Session.state()) :: Session.state()
  def run(name, arg, s) do
    case count(arg) do
      {:ok, n} -> name |> undo_or_redo(s, n) |> undone(name, s)
      :error -> Notify.error(s, "/#{name} [n]: n steps, 1 or more (/#{name} alone is one)")
    end
  end

  defp count(""), do: {:ok, 1}

  defp count(arg) do
    case Integer.parse(arg) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp undo_or_redo("undo", s, n), do: Undo.undo(s.cwd, s.id, n)
  defp undo_or_redo("redo", s, n), do: Undo.redo(s.cwd, s.id, n)

  defp undone({:ok, steps}, name, s) do
    log_undone(steps, name, s)
    labels = Enum.map(steps, & &1.label)
    s = %{s | history: s.history ++ [%{role: "user", content: undo_note(name, labels)}]}
    details = branch_moved(steps, name) <> outside(steps) <> not_covered(steps, name)
    Notify.notice(s, undo_notice(name, labels) <> Enum.map_join(labels, &"  #{&1}\n") <> details)
  end

  defp undone({:error, reason}, name, s), do: Notify.error(s, undo_error(reason, name))

  defp log_undone(steps, name, s) do
    {type, qualifier} = if name == "undo", do: {"step_undone", "undoes"}, else: {"step_redone", "redoes"}
    Log.append(s.log, s.id, Enum.map(steps, &undo_event(&1, type, qualifier)))
  end

  defp undo_event(step, type, qualifier) do
    attrs = %{"effect_id" => step.id, "label" => step.label}
    Log.Event.new(type, {String.to_atom(type), step.id, step.label}, attrs, [{step.id, "effect", qualifier}])
  end

  defp branch_moved(steps, name) do
    case Enum.filter(steps, &is_map(&1.git)) do
      [] ->
        ""

      commits ->
        last = List.last(commits)
        {way, commit} = if name == "undo", do: {"back", last.git.from}, else: {"forward", last.git.to}
        "#{String.replace_prefix(last.git.ref, "refs/heads/", "")}: #{way} to #{String.slice(commit, 0, 7)}\n"
    end
  end

  defp outside(steps) do
    case Enum.flat_map(steps, & &1.outside) do
      [] -> ""
      paths -> "outside the workspace: #{paths |> Enum.uniq() |> Enum.join(", ")}\n"
    end
  end

  # Undo removes the oversized files a step created; redo cannot bring them back.
  defp not_covered(steps, "undo") do
    created = Enum.flat_map(steps, & &1.created)

    files_line("removed (over 5 MB, so /redo cannot bring them back)", created) <>
      left(Enum.flat_map(steps, & &1.skipped) -- created)
  end

  defp not_covered(steps, "redo"), do: left(Enum.flat_map(steps, & &1.skipped))

  defp left(files), do: files_line("not covered (over 5 MB, left as they are)", files)

  defp files_line(_what, []), do: ""
  defp files_line(what, files), do: "#{what}: #{files |> Enum.uniq() |> Enum.join(", ")}\n"

  defp undo_notice("undo", labels), do: "undid #{steps(labels)} (/redo reverses this):\n"
  defp undo_notice("redo", labels), do: "redid #{steps(labels)}:\n"

  defp undo_note("undo", labels),
    do: "(I undid #{length(labels)} of your steps: #{Enum.join(labels, "; ")}. Those files are as they were before them.)"

  defp undo_note("redo", labels),
    do: "(I redid #{length(labels)} of your steps that I had undone: #{Enum.join(labels, "; ")}.)"

  defp steps(labels), do: plural(length(labels))
  defp plural(1), do: "1 step"
  defp plural(n), do: "#{n} steps"

  defp undo_error({:only, n}, name), do: "only #{plural(n)} to #{name}; nothing was #{name}ne"

  defp undo_error({:conflict, step}, name),
    do: "can't #{name} #{step.label}: those lines changed since; nothing was #{name}ne"

  defp undo_error({cause, step, detail}, name), do: "can't #{name} #{step.label}: " <> step_error(cause, detail, name)
  defp undo_error(nothing, name) when nothing in [:nothing_to_undo, :nothing_to_redo], do: "nothing to #{name}"

  defp undo_error(_unavailable_or_changed, name),
    do: "can't #{name} now: no snapshot of the workspace (no git, or too many files), or it changed meanwhile"

  defp step_error(:outside_changed, path, name), do: "#{path} changed since; nothing was #{name}ne"
  defp step_error(:git, reason, name), do: git_error(reason, name)

  defp git_error({:pushed, commit}, _name) do
    short = String.slice(commit, 0, 7)
    "commit #{short} is already pushed; to reverse it, run: git revert #{short}"
  end

  defp git_error(:moved, name), do: "it moved HEAD (checkout, reset or rebase); #{name} that with git"
  defp git_error(:branch_moved, name), do: "its branch has moved since; nothing was #{name}ne"
end
