defmodule Xeito.Tui.Banner do
  @moduledoc """
  The text the TUI starts a session with: the banner, the session line and the earlier turns.

  Each function returns transcript lines (strings without a newline). Only `banner/2` reads
  anything: the workspace's `AGENTS.md` and the skills it and the user have.
  """

  alias Xeito.Session.Router

  @doc "The session line under the banner; `continued` when an earlier session is continued."
  @spec header(String.t(), boolean()) :: String.t()
  def header(session, true), do: "continuing session #{session} · /sessions · /help · Esc halts · /quit"
  def header(session, false), do: "session #{session} · /help · Esc halts · /quit"

  @doc "The banner above the session line; `opts[:home]` is where the user's skills are."
  @spec banner(String.t() | nil, keyword()) :: [String.t()]
  def banner(cwd, opts \\ []) do
    [
      "Enter sends · \\ Enter new line · Esc halts · Up/Down recall · Tab completes · Ctrl-J steers · Ctrl-T status bar · /help",
      "try: fix the failing test · run the checks · commit these changes · explain this code",
      "machines: #{Enum.join(Enum.sort(Map.keys(Router.machines())), " · ")}"
    ] ++ agents_lines(cwd) ++ skills_lines(cwd, opts) ++ [""]
  end

  defp agents_lines(nil), do: ["no AGENTS.md"]

  defp agents_lines(cwd) do
    path = Path.join(cwd, "AGENTS.md")

    case File.read(path) do
      {:ok, text} -> text |> String.split("\n") |> Enum.reject(&(String.trim(&1) == "")) |> agents_excerpt(path)
      {:error, _} -> ["no AGENTS.md in #{cwd}"]
    end
  end

  defp agents_excerpt([], path), do: ["AGENTS.md is empty (#{path})"]

  defp agents_excerpt([first | rest], path) do
    more = if length(rest) > 2, do: ["  … (#{path})"], else: []
    ["AGENTS.md: " <> first] ++ Enum.map(Enum.take(rest, 2), &"  #{&1}") ++ more
  end

  defp skills_lines(nil, _opts), do: ["no skills"]

  defp skills_lines(cwd, opts) do
    %{listed: listed} = cwd |> Xeito.Skills.discover(opts) |> Xeito.Skills.for_turn(cwd, "")
    yours = length(Xeito.Skills.discover(cwd, opts)) - length(listed)
    [skills_line(Enum.map(listed, &"/skill:#{&1.name}"), yours, cwd)]
  end

  defp skills_line([], 0, cwd), do: "no skills in #{cwd}"
  defp skills_line([], yours, _cwd), do: "no skills here · #{yours} of yours (/skill: then Tab)"
  defp skills_line(here, 0, _cwd), do: "skills here: " <> Enum.join(here, " · ")

  defp skills_line(here, yours, _cwd),
    do: "skills here: #{Enum.join(here, " · ")} · and #{yours} of yours (/skill: then Tab)"

  @doc "Earlier turns: each prompt's first line, each earlier answer's first line, the last answer in full."
  @spec transcript_lines([map()]) :: [String.t()]
  def transcript_lines(turns) do
    last = length(turns) - 1

    turns
    |> Enum.with_index()
    |> Enum.flat_map(fn {turn, i} ->
      ["> " <> first_line(turn["prompt"] || "")] ++ answer_lines(turn["answer"], i == last)
    end)
  end

  defp answer_lines(answer, _last) when answer in [nil, ""], do: []
  defp answer_lines(answer, true), do: String.split(answer, "\n")
  defp answer_lines(answer, false), do: [first_line(answer)]

  defp first_line(text), do: text |> String.split("\n") |> hd()
end
