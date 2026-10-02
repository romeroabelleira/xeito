defmodule Xeito.Decisions.Risk do
  @moduledoc """
  Is a proposed shell command safe to run in the workspace?

  Monotonic: rules are authoritative when they fire. Otherwise the result is at least `:review`,
  and a model can only raise it to `:forbidden`. This decision never goes to a remote tier
  (`docs/architecture/10-security-and-sandboxing.md`).
  """

  use Xeito.Decision, version: "2"

  instructions("Is this shell command safe to run automatically inside a software project's workspace?")

  input :command, max_bytes: 1_000
  # The workspace: a command that only writes inside it is safe (see writes_inside?/2).
  input :cwd, max_bytes: 4_096, required: false

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

  # Never safe by rule: actions that delete or run something, forcing, and secrets.
  @excluded ["-delete", "-exec", "--force", ".env", ".ssh", "credentials", ".netrc"]

  @doc false
  def classify(%{command: command} = input) do
    cond do
      Enum.any?(forbidden_patterns(), &Regex.match?(&1, command)) -> :forbidden
      all_segments_safe?(command) -> :safe
      writes_inside?(command, Map.get(input, :cwd) || "") -> :safe
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
      not String.contains?(segment, @excluded)
  end

  # `find` anywhere, without the actions that write or run something; `sed -n` printing line
  # ranges (never `-i`, or scripts that could write or execute); `cd` to a relative directory
  # inside the workspace.
  defp read_only?("find", segment), do: not String.contains?(segment, ["-ok", "-fprint", "-fls"])

  defp read_only?("sed", segment), do: Regex.match?(~r/^sed\s+-n\s+'?\d+(,(\d+|\$))?p'?(\s+[^\s-][^\s;]*)*$/, segment)

  defp read_only?("cd", segment),
    do: Regex.match?(~r/^cd\s+[\w.\/-]+$/, segment) and not Regex.match?(~r/^cd\s+(\/|~|-|\.\.)|\.\./, segment)

  # `xargs` feeding a read-only command (`find … | xargs grep -l x`) is as safe as that command.
  defp read_only?("xargs", segment) do
    rest = Regex.replace(~r/^xargs(\s+-(0|r|t|[nLP]\s*\d+|I\s*\S+|d\s*\S+))*\s+/, segment, "")
    rest != segment and safe_segment?(rest)
  end

  defp read_only?(_word, _segment), do: false

  # --- writes inside the workspace ---------------------------------------------------------
  #
  # A command that writes only inside the workspace is safe: the writes are visible in its text
  # (redirects, tee, touch, mkdir, rm, mv, cp, `sed -i` with one plain substitution), and every
  # path is a literal word that stays inside once resolved on disk, symlinks included. Not the
  # workspace root itself, not .git anywhere, and not a protected directory (dependencies, build
  # output, the log). Anything else (other commands, `$`, `~`, globs, double quotes, long
  # options, a `cd` first) is not provable and goes to review.

  @writers ~w(touch mkdir rm mv cp tee)

  defp writes_inside?(_command, ""), do: false

  defp writes_inside?(command, cwd) do
    with false <- String.contains?(command, @excluded),
         {:ok, segments, redirects} <- parse(command),
         segments = Enum.reject(segments, &(&1 == "")),
         false <- Enum.any?(segments, &String.starts_with?(&1, "cd ")),
         {:ok, paths} <- written_paths(segments, redirects) do
      Enum.all?(paths, &inside?(&1, cwd))
    else
      _ -> false
    end
  end

  defp written_paths(segments, redirects) do
    Enum.reduce_while(segments, {:ok, redirects}, fn segment, {:ok, paths} ->
      case segment_paths(segment) do
        {:ok, more} -> {:cont, {:ok, paths ++ more}}
        :error -> {:halt, :error}
      end
    end)
  end

  # The paths a segment writes ([] for a read-only one), or :error if that is not provable.
  defp segment_paths(segment) do
    if safe_segment?(segment),
      do: {:ok, []},
      else: with({:ok, [command | args]} <- words(segment), do: command_paths(command, args))
  end

  defp command_paths("sed", args), do: sed_paths(args, %{in_place: false, script: nil, files: []})

  defp command_paths(command, args) when command in @writers do
    {options, paths} = Enum.split_with(args, &String.starts_with?(&1, "-"))
    if paths != [] and Enum.all?(options, &Regex.match?(~r/^-[a-zA-Z]+$/, &1)), do: {:ok, paths}, else: :error
  end

  defp command_paths(_command, _args), do: :error

  # `sed -i[SUFFIX] [-i ''] [-E|-r] [-e] 's/a/b/flags' FILE...`
  defp sed_paths(["-i", "" | rest], acc), do: sed_paths(rest, %{acc | in_place: true})
  defp sed_paths(["-i" <> _suffix | rest], acc), do: sed_paths(rest, %{acc | in_place: true})
  defp sed_paths([flag | rest], acc) when flag in ["-E", "-r"], do: sed_paths(rest, acc)
  defp sed_paths(["-e", script | rest], %{script: nil} = acc), do: sed_paths(rest, %{acc | script: script})
  defp sed_paths(["-" <> _ | _], _acc), do: :error
  defp sed_paths([script | rest], %{script: nil} = acc), do: sed_paths(rest, %{acc | script: script})
  defp sed_paths([file | rest], acc), do: sed_paths(rest, %{acc | files: [file | acc.files]})

  defp sed_paths([], %{in_place: true, script: script, files: [_ | _] = files}) do
    if substitution?(script), do: {:ok, files}, else: :error
  end

  defp sed_paths([], _acc), do: :error

  # One `s` command with no flag that writes a file or runs a command (`w`, `e`).
  defp substitution?(script),
    do: Regex.match?(~r/^s([^\w\s\\])(?:(?!\1)[^\\\n]|\\.)*\1(?:(?!\1)[^\\\n]|\\.)*\1[gIi0-9]*$/, script)

  # Shell words: plain ones without anything the shell would expand or interpret, or single-quoted.
  defp words(segment) do
    ~r/(?:'[^']*'|[^\s'])+/
    |> Regex.scan(segment)
    |> Enum.map(fn [word] -> literal(word) end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, word}, {:ok, acc} -> {:cont, {:ok, acc ++ [word]}}
      :error, _ -> {:halt, :error}
    end)
  end

  defp literal(word) do
    cond do
      Regex.match?(~r/^'[^']*'$/, word) -> {:ok, String.slice(word, 1..-2//1)}
      Regex.match?(~r/[$`~*?\[\]{}\\"'()!#]/, word) -> :error
      true -> {:ok, word}
    end
  end

  defp inside?(path, cwd) do
    parts = path |> Path.split() |> Enum.reject(&(&1 == "."))

    Path.type(path) == :relative and parts != [] and ".." not in parts and ".git" not in parts and
      hd(parts) not in Xeito.Tools.protected_dirs() and
      within?(resolve(Path.join([cwd | parts])), resolve(cwd))
  end

  defp within?(path, root) when is_binary(path) and is_binary(root), do: String.starts_with?(path, root <> "/")
  defp within?(_path, _root), do: false

  # The absolute path with every symlink on the way followed (as far as the path exists).
  defp resolve(path), do: follow(Path.split(Path.expand(path)), "/", 40)

  defp follow(_parts, _at, 0), do: :error
  defp follow([], at, _left), do: at

  defp follow([part | rest], at, left) do
    next = Path.join(at, part)

    case File.read_link(next) do
      {:ok, target} -> follow(Path.split(Path.expand(target, at)) ++ rest, "/", left - 1)
      {:error, _} -> follow(rest, next, left)
    end
  end

  # --- a small shell tokenizer -------------------------------------------------------------
  #
  # Splits a command into the segments between unquoted `|`, `||`, `&&`, `;` and newlines,
  # respecting quotes. It is deliberately strict: `:unsafe` for command substitution, process
  # substitution, heredocs, background jobs, unbalanced quotes, and any redirection except to
  # `/dev/null` or between streams (`2>&1`), since other redirections write files.

  # A redirect into a file is a write: `parse/1` returns its target, and `segments/1` (for
  # read-only commands) calls the command unsafe.

  @doc false
  @spec segments(String.t()) :: {:ok, [String.t()]} | :unsafe
  def segments(command) do
    case parse(command) do
      {:ok, segments, []} -> {:ok, segments}
      _ -> :unsafe
    end
  end

  @doc false
  @spec parse(String.t()) :: {:ok, [String.t()], [String.t()]} | :unsafe
  def parse(command) do
    with {:ok, parts} <- scan(String.graphemes(command), nil, [], []) do
      {writes, segments} = Enum.split_with(parts, &match?({:write, _}, &1))
      {:ok, segments, Enum.map(writes, fn {:write, target} -> target end)}
    end
  end

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

  # After `>`, `>>`, `N>` or `&>`: `/dev/null` or another stream (`&1`, `&2`), or a file named by
  # a plain word, which is recorded as a write. The redirection (and a file descriptor number
  # before it) is dropped from the segment.
  defp redirect([">" | rest], cur, acc), do: redirect(rest, cur, acc)

  defp redirect(rest, cur, acc) do
    target = rest |> Enum.join() |> String.trim_leading()
    cur = if match?([d | _] when d in ~w(0 1 2), cur), do: tl(cur), else: cur

    case Regex.run(~r/^(?:(\/dev\/null|&[12-])(?=$|[\s;|&])|([^\s;|&<>()`$"'\\~*?\[\]{}!#]+))/, target) do
      [_, stream] -> skip(rest, target, stream, cur, acc)
      [_, "", file] -> skip(rest, target, file, cur, [{:write, file} | acc])
      nil -> :unsafe
    end
  end

  defp skip(rest, target, word, cur, acc) do
    skipped = String.length(Enum.join(rest)) - String.length(target) + String.length(word)
    scan(Enum.drop(rest, skipped), nil, cur, acc)
  end

  defp segment(cur), do: cur |> Enum.reverse() |> Enum.join() |> String.trim()
end
