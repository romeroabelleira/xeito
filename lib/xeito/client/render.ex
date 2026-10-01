defmodule Xeito.Client.Render do
  @moduledoc """
  Turns daemon events (`Xeito.Api`, string keys) into transcript text, in the style of the
  mockup in `docs/architecture/07-harness-frontend.md`: one line per step that matters, streamed
  model output inline, and everything inside escalation runs folded into its decision.

  Shared by the line-mode client and the TUI, so both show the same transcript.
  """

  @doc "The text for one event (possibly empty). Lines end with a newline; deltas do not."
  @spec line(map()) :: String.t()
  def line(%{"run" => run} = event) when is_binary(run) do
    if internal?(run), do: "", else: render(event, indent(run))
  end

  def line(event), do: render(event, "")

  # Escalation runs are summarised by the decision they produce.
  defp internal?(run), do: String.ends_with?(run, "/esc") or String.ends_with?(run, "/intent")

  # Delegated machines (…/eN/run) are indented one level per delegation.
  defp indent(run), do: String.duplicate("  ", length(Regex.scan(~r{/e\d+/run}, run)))

  defp render(%{"event" => "delta", "attrs" => %{"text" => text}}, _pad), do: text

  defp render(%{"event" => "intent", "attrs" => a}, pad),
    do: "#{pad}◆ intent: #{a["value"]} (#{a["actor"]} #{conf(a["confidence"])})\n"

  defp render(%{"event" => "run_selected", "attrs" => a}, pad), do: "#{pad}  → #{short(a["machine"])} · #{a["reason"]}\n"

  defp render(%{"event" => "decision_made", "attrs" => a}, pad) do
    type = a["decision_type"] |> to_string() |> short() |> Macro.underscore()
    "#{pad}◆ #{type}: #{a["value"]} (#{a["actor"]} #{conf(a["confidence"])})\n"
  end

  defp render(%{"event" => "effect_requested", "attrs" => %{"kind" => kind, "args" => args}}, pad) do
    case {to_string(kind), args} do
      {"bash", %{"cmd" => cmd}} -> "#{pad}  $ #{cmd}\n"
      {"read", %{"path" => _} = a} -> "#{pad}  #{read_label(a)}\n"
      {"write", %{"path" => p} = a} -> "#{pad}  write #{p} (#{count_lines(a["content"])} lines)\n"
      {"edit", %{"path" => p} = a} -> "#{pad}  edit #{p}\n" <> diff(a["old"], a["new"], pad)
      {"machine", %{"machine" => m}} -> "#{pad}  ↳ delegating to #{short(m)}\n"
      {"chat", _} -> pad
      _ -> ""
    end
  end

  defp render(%{"event" => "effect_completed", "attrs" => %{"kind" => kind, "result" => r}}, pad) do
    case {to_string(kind), r} do
      {"bash", %{"exit_status" => status, "output" => out}} ->
        "#{pad}    exit #{status}#{tail(out)}\n"

      {"chat", %{"error" => error}} ->
        "\n#{pad}  ✗ model error: #{inspect(error)}\n"

      {"chat", _} ->
        "\n"

      {k, %{"ok" => false, "error" => error}} when k in ~w(read write edit) ->
        "#{pad}    ✗ #{error}\n"

      {k, %{"syntax_error" => error}} when k in ~w(write edit) ->
        "#{pad}    ⚠ no longer parses: #{error}\n"

      _ ->
        ""
    end
  end

  # The chat loop's own states are visible through its tool calls and streamed text.
  defp render(%{"event" => "state_entered", "attrs" => %{"state" => state}}, _pad)
       when state in ["risk_check", "thinking", "executing", "answered"], do: ""

  defp render(%{"event" => "state_entered", "attrs" => %{"state" => state}}, pad), do: "#{pad}· #{state}\n"

  defp render(%{"event" => "human_needed", "attrs" => %{"call" => call}}, pad) do
    what =
      case call do
        %{"tool" => "bash", "arguments" => %{"command" => cmd}} -> "run `#{cmd}`"
        %{"summary" => summary} -> summary
        %{"tool" => tool} -> tool
        _ -> "continue"
      end

    "#{pad}? review: #{what} — approve with y, deny with n\n"
  end

  # A chat answer was already streamed; other machines get a one-line summary.
  defp render(%{"event" => "paused", "attrs" => a}, pad) do
    "#{pad}‖ paused in #{a["state"]} before #{paused_what(a)} — /next · /decide <value> · /continue\n"
  end

  defp render(%{"event" => "turn_finished", "attrs" => a}, _pad) do
    mark = if to_string(a["status"]) == "done", do: "✓", else: "✗"
    answer = a["answer"]

    summary =
      if answer in [nil, ""] or to_string(a["final_state"]) == "answered",
        do: "",
        else: " · " <> first_line(answer)

    "#{mark} #{a["final_state"]}#{summary}\n"
  end

  defp render(%{"event" => "closed"}, _pad), do: "· session closed while idle; the next prompt resumes it from the log\n"

  defp render(%{"event" => "notice", "attrs" => %{"text" => text}}, _pad), do: text <> "\n"
  defp render(%{"event" => "error", "attrs" => %{"text" => text}}, _pad), do: "✗ " <> text <> "\n"
  defp render(_event, _pad), do: ""

  defp read_label(%{"result" => r}), do: "read result #{r}"
  defp read_label(%{"path" => p, "lines" => l}), do: "read #{p} · lines #{l}"
  defp read_label(%{"path" => p, "symbol" => s}), do: "read #{p} · #{s}"
  defp read_label(%{"path" => p, "outline" => true}), do: "outline #{p}"
  defp read_label(%{"path" => p}), do: "read #{p}"

  defp paused_what(%{"summary" => %{"decision" => d, "value" => v} = sm}),
    do: "#{d |> to_string() |> short()}: #{v} (#{sm["actor"]} #{conf(sm["confidence"])})"

  defp paused_what(%{"summary" => %{"exit_status" => status}, "kind" => kind}), do: "#{kind} exit #{status}"

  defp paused_what(a), do: "#{a["kind"]} result"

  # A compact diff of an edit: removed lines, then added lines, a few of each.
  @diff_lines 6

  defp diff(old, new, pad) when is_binary(old) and is_binary(new) do
    side(old, "-", pad) <> side(new, "+", pad)
  end

  defp diff(_old, _new, _pad), do: ""

  defp side(text, mark, pad) do
    lines = String.split(text, "\n")
    shown = Enum.take(lines, @diff_lines)
    more = length(lines) - length(shown)

    Enum.map_join(shown, fn line -> "#{pad}    #{mark} #{line}\n" end) <>
      if(more > 0, do: "#{pad}    #{mark} … #{more} more\n", else: "")
  end

  defp count_lines(text) when is_binary(text), do: length(String.split(text, "\n"))
  defp count_lines(_text), do: 0

  defp conf(nil), do: "-"
  defp conf(c) when is_number(c), do: :erlang.float_to_binary(c * 1.0, decimals: 2)
  defp conf(c), do: to_string(c)

  defp short(module), do: module |> to_string() |> String.split(".") |> List.last()

  defp tail(""), do: ""

  defp tail(out) do
    out
    |> String.trim()
    |> String.split("\n")
    |> List.last()
    |> then(&" · #{String.slice(&1, 0, 100)}")
  end

  defp first_line(text), do: text |> String.trim() |> String.split("\n") |> hd() |> String.slice(0, 160)
end
