defmodule Xeito.Decisions.Risk do
  @moduledoc """
  Is a proposed shell command safe to run in the workspace?

  Monotonic: rules are authoritative when they fire. Otherwise the result is at least `:review`,
  and a model can only raise it to `:forbidden`. This decision never goes to a remote tier
  (`docs/architecture/10-security-and-sandboxing.md`).
  """

  use Xeito.Decision, version: "1"

  instructions("Is this shell command safe to run automatically inside a software project's workspace?")

  input :command, max_bytes: 1_000

  value :safe, "read-only or routine development command with no destructive or external effect"

  value(
    :review,
    "changes state outside the project, deletes data, installs software or needs privileges; a human should confirm"
  )

  value(
    :forbidden,
    "destroys data or systems, exfiltrates secrets, pipes remote code into a shell, or disables safety"
  )

  rule :classify

  severity [:safe, :review, :forbidden], floor: :review
  policy remote: :forbidden

  # Small tiers failed the zero-shot gate in P2 (bench/2-decisions.md); they decide again once they pass.
  deciders [:large]
  min_confidence 0.7

  # Regexes cannot live in module attributes on OTP 28+, so they are built in a function.
  defp forbidden_patterns do
    [
      ~r/\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*([rR][a-zA-Z]*f|f[a-zA-Z]*[rR])[a-zA-Z]*\s+(\/|~|\$HOME|\/\*|\*|\.\.)(\s|\/?$|\/\*)/,
      ~r/\brm\s+.*--no-preserve-root/,
      ~r/\brm\s+(-[a-zA-Z]+\s+)*(\/|~\/?|\$HOME\/?)\s*$/,
      ~r/\bmkfs(\.\w+)?\b/,
      ~r/\bdd\s+.*\bof=\/dev\//,
      ~r/>\s*\/dev\/(sd|nvme|hd|vd|disk)/,
      ~r/\b(wipefs|shred)\b.*\/dev\//,
      ~r/:\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:/,
      ~r/\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|da|k)?sh\b/,
      ~r/\b(sh|bash|zsh)\s+(-c\s+)?["']?\$\((curl|wget)\b/,
      ~r/\beval\s+["']?\$\((curl|wget)\b/,
      ~r/base64\s+(-d|--decode)\b.*\|\s*(ba|z)?sh\b/,
      ~r/\bchmod\s+(-R\s+)?[0-7]?777\s+\/(\s|$)/,
      ~r/\bchown\s+-R\s+\S+\s+\/(\s|$)/,
      ~r/(>|\btee\b)\s*(-a\s+)?\/etc\/(passwd|shadow|sudoers|hosts)\b/,
      ~r/\b(curl|wget|nc|ncat|scp|rsync)\b.*(\.ssh\/id_|\.aws\/credentials|\.gnupg|\.netrc|\.env\b)/,
      ~r/(\.ssh\/id_\w+|\.aws\/credentials|\.netrc)\b.*\|\s*(curl|nc|ncat)\b/,
      ~r/\bkill\s+-9\s+-1\b/,
      ~r/\b(shutdown|reboot|poweroff|halt)\b/,
      ~r/\biptables\s+(-F|--flush)\b/,
      ~r/\bfind\s+\/\s.*-delete\b/,
      ~r/\bcrontab\s+-r\b/,
      ~r/\bgit\s+push\s+.*(--force|-f)\b.*\b(main|master)\b/,
      ~r/\bmv\s+(\/|~|\$HOME)\s+\/dev\/null/,
      ~r/\bhistory\s+-c\b.*&&.*\b(rm|curl)\b/
    ]
  end

  @safe_commands ~w(ls cat head tail grep rg pwd echo wc which tree stat du df diff less file sort uniq cut)
  @safe_prefixes [
    "git status",
    "git diff",
    "git log",
    "git show",
    "git branch",
    "git blame",
    "mix test",
    "mix compile",
    "mix format",
    "mix deps.get",
    "mix credo",
    "npm test",
    "npm run test",
    "npm run lint",
    "pytest",
    "python -m pytest",
    "python3 -m pytest",
    "cargo test",
    "cargo build",
    "cargo check",
    "go test",
    "go build",
    "make test",
    "bundle exec rspec"
  ]

  @doc false
  def classify(%{command: command}) do
    cond do
      Enum.any?(forbidden_patterns(), &Regex.match?(&1, command)) -> :forbidden
      all_segments_safe?(command) -> :safe
      true -> nil
    end
  end

  defp all_segments_safe?(command) do
    case segments(command) do
      {:ok, segments} -> segments |> Enum.reject(&(&1 == "")) |> Enum.all?(&safe_segment?/1)
      :unsafe -> false
    end
  end

  defp safe_segment?(segment) do
    [word | _] = String.split(segment, ~r/\s+/, parts: 2) ++ [""]

    (word in @safe_commands or Enum.any?(@safe_prefixes, &String.starts_with?(segment, &1)) or
       read_only?(word, segment)) and
      not String.contains?(segment, [
        "-delete",
        "-exec",
        "--force",
        ".env",
        ".ssh",
        "credentials",
        ".netrc"
      ])
  end

  # `find` anywhere, without the actions that write or run something; `sed -n` printing line
  # ranges (never `-i`, or scripts that could write or execute); `cd` to a relative directory
  # inside the workspace.
  defp read_only?("find", segment), do: not String.contains?(segment, ["-ok", "-fprint", "-fls"])

  defp read_only?("sed", segment), do: Regex.match?(~r/^sed\s+-n\s+'?\d+(,(\d+|\$))?p'?(\s+[^\s-][^\s;]*)*$/, segment)

  defp read_only?("cd", segment),
    do: Regex.match?(~r/^cd\s+[\w.\/-]+$/, segment) and not Regex.match?(~r/^cd\s+(\/|~|-|\.\.)|\.\./, segment)

  defp read_only?(_word, _segment), do: false

  # --- a small shell tokenizer -------------------------------------------------------------
  #
  # Splits a command into the segments between unquoted `|`, `||`, `&&`, `;` and newlines,
  # respecting quotes. It is deliberately strict: `:unsafe` for command substitution, process
  # substitution, heredocs, background jobs, unbalanced quotes, and any redirection except to
  # `/dev/null` or between streams (`2>&1`), since other redirections write files.

  @doc false
  @spec segments(String.t()) :: {:ok, [String.t()]} | :unsafe
  def segments(command), do: scan(String.graphemes(command), nil, [], [])

  defp scan([], nil, cur, acc), do: {:ok, Enum.reverse([segment(cur) | acc])}
  defp scan([], _quote, _cur, _acc), do: :unsafe

  # Inside single quotes nothing is special.
  defp scan(["'" | rest], "'", cur, acc), do: scan(rest, nil, ["'" | cur], acc)
  defp scan([c | rest], "'", cur, acc), do: scan(rest, "'", [c | cur], acc)
  defp scan(["'" | rest], nil, cur, acc), do: scan(rest, "'", ["'" | cur], acc)

  # Substitution runs a command, also inside double quotes.
  defp scan(["`" | _], _quote, _cur, _acc), do: :unsafe
  defp scan(["$", "(" | _], _quote, _cur, _acc), do: :unsafe
  defp scan(["\\", c | rest], quote, cur, acc), do: scan(rest, quote, [c, "\\" | cur], acc)
  defp scan(["\"" | rest], "\"", cur, acc), do: scan(rest, nil, ["\"" | cur], acc)
  defp scan([c | rest], "\"", cur, acc), do: scan(rest, "\"", [c | cur], acc)
  defp scan(["\"" | rest], nil, cur, acc), do: scan(rest, "\"", ["\"" | cur], acc)

  # Unquoted operators.
  defp scan(["&", "&" | rest], nil, cur, acc), do: split(rest, cur, acc)
  defp scan(["|", "|" | rest], nil, cur, acc), do: split(rest, cur, acc)
  defp scan([op | rest], nil, cur, acc) when op in ["|", ";", "\n"], do: split(rest, cur, acc)
  defp scan(["&", ">" | rest], nil, cur, acc), do: redirect(rest, cur, acc)
  defp scan(["&" | _], nil, _cur, _acc), do: :unsafe
  defp scan([">" | rest], nil, cur, acc), do: redirect(rest, cur, acc)
  defp scan(["<", c | _], nil, _cur, _acc) when c in ["(", "<"], do: :unsafe
  defp scan([c | rest], nil, cur, acc), do: scan(rest, nil, [c | cur], acc)

  defp split(rest, cur, acc), do: scan(rest, nil, [], [segment(cur) | acc])

  # After `>`, `>>`, `N>` or `&>`: only `/dev/null` or another stream (`&1`, `&2`) is allowed.
  # The redirection (and a file descriptor number before it) is dropped from the segment.
  defp redirect([">" | rest], cur, acc), do: redirect(rest, cur, acc)

  defp redirect(rest, cur, acc) do
    target = rest |> Enum.join() |> String.trim_leading()

    case Regex.run(~r/^(\/dev\/null|&[12-])(?=$|[\s;|&])/, target) do
      [_, t] ->
        skipped = String.length(Enum.join(rest)) - String.length(target) + String.length(t)
        cur = if match?([d | _] when d in ~w(0 1 2), cur), do: tl(cur), else: cur
        scan(Enum.drop(rest, skipped), nil, cur, acc)

      nil ->
        :unsafe
    end
  end

  defp segment(cur), do: cur |> Enum.reverse() |> Enum.join() |> String.trim()
end
