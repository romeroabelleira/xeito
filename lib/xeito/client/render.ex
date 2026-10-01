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

  defp render(%{"event" => "effect_requested", "attrs" => %{"kind" => kind, "args" => args}}, pad),
    do: requested(to_string(kind), args, pad)

  defp render(%{"event" => "effect_completed", "attrs" => %{"kind" => kind, "result" => r}}, pad),
    do: completed(to_string(kind), r, pad)

  # The chat loop's own states are visible through its tool calls and streamed text.
  defp render(%{"event" => "state_entered", "attrs" => %{"state" => state}}, _pad)
       when state in ["risk_check", "thinking", "executing", "answered"], do: ""

  defp render(%{"event" => "state_entered", "attrs" => %{"state" => state}}, pad), do: "#{pad}· #{state}\n"

  defp render(%{"event" => "human_needed", "attrs" => %{"call" => call}}, pad),
    do: "#{pad}? review: #{review_what(call)} — approve with y, deny with n\n"

  # A chat answer was already streamed; other machines get a one-line summary.
  defp render(%{"event" => "paused", "attrs" => a}, pad) do
    "#{pad}‖ paused in #{a["state"]} before #{paused_what(a)} — /next · /decide <value> · /continue\n"
  end

  defp render(%{"event" => "turn_finished", "attrs" => a}, _pad) do
    mark = if to_string(a["status"]) == "done", do: "✓", else: "✗"
    "#{mark} #{a["final_state"]}#{answer_summary(a)}\n"
  end

  defp render(%{"event" => "closed"}, _pad), do: "· session closed while idle; the next prompt resumes it from the log\n"

  defp render(%{"event" => "notice", "attrs" => %{"text" => text}}, _pad), do: text <> "\n"
  defp render(%{"event" => "error", "attrs" => %{"text" => text}}, _pad), do: "✗ " <> text <> "\n"
  defp render(_event, _pad), do: ""

  defp requested("bash", %{"cmd" => cmd}, pad), do: "#{pad}  $ #{cmd}\n"
  defp requested("read", %{"path" => _} = a, pad), do: "#{pad}  #{read_label(a)}\n"
  defp requested("write", %{"path" => p} = a, pad), do: "#{pad}  write #{p} (#{count_lines(a["content"])} lines)\n"
  defp requested("edit", %{"path" => p} = a, pad), do: "#{pad}  edit #{p}\n" <> diff(a["old"], a["new"], pad)
  defp requested("machine", %{"machine" => m}, pad), do: "#{pad}  ↳ delegating to #{short(m)}\n"
  defp requested("chat", _args, pad), do: pad
  defp requested(_kind, _args, _pad), do: ""

  defp completed("bash", %{"exit_status" => status, "output" => out}, pad), do: "#{pad}    exit #{status}#{tail(out)}\n"
  defp completed("chat", %{"error" => error}, pad), do: "\n#{pad}  ✗ model error: #{inspect(error)}\n"
  defp completed("chat", _result, _pad), do: "\n"

  defp completed(kind, %{"ok" => false, "error" => error}, pad) when kind in ~w(read write edit),
    do: "#{pad}    ✗ #{error}\n"

  defp completed(kind, %{"syntax_error" => error}, pad) when kind in ~w(write edit),
    do: "#{pad}    ⚠ no longer parses: #{error}\n"

  defp completed(_kind, _result, _pad), do: ""

  defp review_what(%{"tool" => "bash", "arguments" => %{"command" => cmd}}), do: "run `#{cmd}`"
  defp review_what(%{"summary" => summary}), do: summary
  defp review_what(%{"tool" => tool}), do: tool
  defp review_what(_call), do: "continue"

  # A chat answer was already streamed.
  defp answer_summary(%{"answer" => answer}) when answer in [nil, ""], do: ""
  defp answer_summary(%{"final_state" => state}) when state in ["answered", :answered], do: ""
  defp answer_summary(%{"answer" => answer}), do: " · " <> first_line(answer)
  defp answer_summary(_attrs), do: ""

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
