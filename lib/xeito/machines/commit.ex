defmodule Xeito.Machines.Commit do
  @moduledoc """
  Commits the workspace's changes with a drafted message that a human approves.

      inspecting ─┬─ not a repository ──→ failed
                  ├─ nothing to commit ──→ done
                  └─ changes ──→ drafting ──→ ask_human ─┬─ approved → writing → committing → done | failed
                                                         └─ denied ──→ cancelled

  * The model only drafts the message (no tools); the commands are fixed and run by the machine.
  * Staged changes are committed as they are. With nothing staged, everything is staged first
    (`git add -A`, so `.gitignore` applies).
  * Commit hooks run as usual. A failing hook ends the run in `failed` with its output.

  Input: `%{cwd: path}`, optionally `request` (the user's words, a hint for the message).
  """

  use Xeito.Machine, version: "0.1.0"

  alias Xeito.Effect

  @max_diff 24_000
  @message_file ".xeito/COMMIT_MSG"

  initial :inspecting

  state :inspecting, entry: :inspect_changes, timeout: 60_000 do
    on :ran, to: :failed, guard: :failed?, action: :record_error
    on :ran, to: :done, guard: :clean?, action: :record_clean
    on :ran, to: :drafting, action: :record_changes
  end

  state :drafting, entry: :draft, timeout: 300_000 do
    on :chatted, to: :failed, guard: :chat_error?, action: :record_error
    on :chatted, to: :ask_human, action: :record_message
  end

  state :ask_human, timeout: {86_400_000, :denied} do
    on :approved, to: :writing
    on :denied, to: :cancelled
  end

  state :writing, entry: :write_message, timeout: 10_000 do
    on :written, to: :committing, guard: :written?
    on :written, to: :failed, action: :record_error
  end

  state :committing, entry: :commit, timeout: 300_000 do
    on :ran, to: :done, guard: :passed?, action: :record_commit
    on :ran, to: :failed, action: :record_error
  end

  final :done
  final :failed
  final :cancelled

  # --- entry functions ---------------------------------------------------------------------

  @doc false
  def inspect_changes(ctx) do
    cmd =
      "git rev-parse --is-inside-work-tree >/dev/null && git status --short && echo '@@diff@@' && " <>
        "(if git diff --cached --quiet; then git diff HEAD; else git diff --cached; fi) | head -c #{@max_diff}"

    [Effect.bash(cmd, cwd: ctx.cwd, timeout: 60_000)]
  end

  @doc false
  def draft(ctx) do
    system = """
    Write a git commit message for the changes below. The first line is an imperative summary
    of at most 72 characters. For a change that is not trivial, add a blank line and a few
    short bullet points about what changed and why. Output only the message, no code fences.
    """

    hint = if ctx[:request], do: "The user asked: #{ctx.request}\n\n", else: ""
    user = hint <> "git status --short:\n#{ctx.status}\n\nDiff:\n#{ctx.diff}"

    [
      Effect.chat([%{role: "system", content: system}, %{role: "user", content: user}],
        tools: false
      )
    ]
  end

  @doc false
  def write_message(ctx), do: [Effect.write(@message_file, ctx.message <> "\n", cwd: ctx.cwd)]

  @doc false
  def commit(ctx) do
    cmd =
      "(git diff --cached --quiet && git add -A); " <>
        "git commit -q -F #{@message_file} && rm -f #{@message_file} && git log -1 --format='%h %s'"

    [Effect.bash(cmd, cwd: ctx.cwd, timeout: 300_000)]
  end

  # --- guards ------------------------------------------------------------------------------

  @doc false
  def failed?(_ctx, result), do: result.exit_status != 0
  @doc false
  def passed?(_ctx, result), do: result.exit_status == 0
  @doc false
  def clean?(_ctx, result), do: status(result.output) == ""
  @doc false
  def chat_error?(_ctx, message), do: Map.has_key?(message, :error)
  @doc false
  def written?(_ctx, result), do: result[:ok] == true

  # --- actions -----------------------------------------------------------------------------

  @doc false
  def record_changes(ctx, result) do
    [status, diff | _] = String.split(result.output, "@@diff@@\n", parts: 2) ++ [""]
    Map.merge(ctx, %{status: String.trim(status), diff: diff})
  end

  @doc false
  def record_clean(ctx, _result), do: Map.put(ctx, :answer, "Nothing to commit.")

  @doc false
  def record_message(ctx, message) do
    text = message |> Map.get(:content, "") |> strip_fences()
    files = ctx.status |> String.split("\n", trim: true) |> length()
    review = "commit #{files} file#{if files == 1, do: "", else: "s"}: " <> first_line(text)
    Map.merge(ctx, %{message: text, review: review})
  end

  @doc false
  def record_commit(ctx, result),
    do: Map.put(ctx, :answer, "Committed " <> String.trim(result.output))

  @doc false
  def record_error(ctx, result),
    do: Map.put(ctx, :error, result[:output] || result[:error] || inspect(result))

  defp status(output), do: output |> String.split("@@diff@@", parts: 2) |> hd() |> String.trim()

  defp strip_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/\A```[a-z]*\n/, "")
    |> String.replace(~r/\n```\z/, "")
    |> String.trim()
  end

  defp first_line(text), do: text |> String.split("\n") |> hd()
end
