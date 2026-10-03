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
  # Writes the rules cannot prove from the text, but undo can take back (undo stage 3).
  rule :undoable

  severity [:safe, :review, :forbidden], floor: :review
  policy remote: :forbidden

  # Small tiers failed the zero-shot gate in P2 (bench/2-decisions.md); they decide again once they pass.
  deciders [:local]
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

  defp read_only?("cd", segment), do: into_subdirectory?(segment)

  # `xargs` feeding a read-only command (`find … | xargs grep -l x`) is as safe as that command.
  defp read_only?("xargs", segment) do
    rest = Regex.replace(~r/^xargs(\s+-(0|r|t|[nLP]\s*\d+|I\s*\S+|d\s*\S+))*\s+/, segment, "")
    rest != segment and safe_segment?(rest)
  end

  defp read_only?(_word, _segment), do: false

  defp into_subdirectory?(segment),
    do: Regex.match?(~r/^cd\s+[\w.\/-]+$/, segment) and not Regex.match?(~r/^cd\s+(\/|~|-|\.\.)|\.\./, segment)

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
    with false <- String.contains?(command, @excluded), {:ok, paths} <- written_paths(command) do
      Enum.all?(paths, &inside?(&1, cwd))
    else
      _ -> false
    end
  end

  @doc """
  The paths `command` writes, as written (relative or absolute): `{:ok, paths}` when every one
  is a literal word the rules can name (redirects first, then each command's), `:error`
  otherwise. Undo backs up those outside the workspace (`Xeito.Undo`).
  """
  @spec written_paths(String.t()) :: {:ok, [String.t()]} | :error
  def written_paths(command), do: paths(command, &segment_paths/1)

  defp paths(command, segment_paths) do
    with {:ok, segments, redirects} <- parse(command),
         segments = Enum.reject(segments, &(&1 == "")),
         false <- Enum.any?(segments, &String.starts_with?(&1, "cd ")) do
      collect_paths(segments, redirects, segment_paths)
    else
      _ -> :error
    end
  end

  defp collect_paths(segments, redirects, segment_paths) do
    Enum.reduce_while(segments, {:ok, redirects}, fn segment, {:ok, paths} ->
      case segment_paths.(segment) do
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

  defp command_paths("sed", args), do: args |> sed_options(%{in_place: false, script: nil}) |> sed_files()

  defp command_paths(command, args) when command in @writers do
    {options, paths} = Enum.split_with(args, &String.starts_with?(&1, "-"))
    if paths != [] and Enum.all?(options, &Regex.match?(~r/^-[a-zA-Z]+$/, &1)), do: {:ok, paths}, else: :error
  end

  defp command_paths(_command, _args), do: :error

  # `sed -i[SUFFIX] [-i ''] [-E|-r] [-e SCRIPT] [SCRIPT] FILE...`: the options first, then the
  # files. Any other option ends the options and fails below, as a script or as a file.
  defp sed_options(["-i", "" | rest], acc), do: sed_options(rest, %{acc | in_place: true})
  defp sed_options(["-i" <> _suffix | rest], acc), do: sed_options(rest, %{acc | in_place: true})
  defp sed_options([flag | rest], acc) when flag in ["-E", "-r"], do: sed_options(rest, acc)
  defp sed_options(["-e", script | rest], %{script: nil} = acc), do: sed_options(rest, %{acc | script: script})
  defp sed_options(rest, acc), do: {acc, rest}

  defp sed_files({%{in_place: true, script: nil} = acc, [script | files]}),
    do: sed_files({%{acc | script: script}, files})

  # Every file is a path: an option after the script is refused, not guessed.
  defp sed_files({%{in_place: true, script: script}, [_ | _] = files}) do
    if one_substitution?(script) and not Enum.any?(files, &String.starts_with?(&1, "-")), do: {:ok, files}, else: :error
  end

  defp sed_files(_parsed), do: :error

  # One `s` command with no flag that writes a file or runs a command (`w`, `e`).
  defp one_substitution?(script),
    do: Regex.match?(~r/^s([^\w\s\\])(?:(?!\1)[^\\\n]|\\.)*\1(?:(?!\1)[^\\\n]|\\.)*\1[gIi0-9]*$/, script)

  # --- writes undo can take back (undo stage 3) ---------------------------------------------
  #
  # Some writes stay inside the workspace though the rules above cannot prove it from the text:
  # globs, options they do not know, `find … -delete`. Each pattern is expanded in the
  # workspace, and when every path stays inside it (as above) and a snapshot would hold
  # everything under it (`Xeito.Undo.covers?/3`), the step can be undone: it is safe, decided
  # as `rule:undoable` so the log shows what undo made safe. Secrets, `-exec`, dot-globs (which
  # match `.git` or `.env`) and anything but plain writers still go to review.

  @not_undoable [".env", ".ssh", "credentials", ".netrc", "-exec", "-ok", "-fprint", "-fls"]

  @doc false
  # Without a workspace there is no snapshot to cover anything (`Xeito.Undo.covers?/3`).
  def undoable(%{command: command} = input), do: undoable(command, Map.get(input, :cwd) || "")

  defp undoable(command, cwd) do
    with false <- String.contains?(command, @not_undoable),
         {:ok, patterns} <- paths(command, &confined_segment/1),
         true <- confined?(patterns, cwd) and covered?(patterns, cwd) do
      :safe
    else
      _ -> nil
    end
  end

  # No dot-globs, and every glob's leading directories inside the workspace.
  defp confined?(patterns, cwd),
    do: not Enum.any?(patterns, &dot_glob?/1) and Enum.all?(patterns, &glob_root_inside?(&1, cwd))

  # Every path, expanded, is inside, names no secret, and lies in what a snapshot holds.
  defp covered?(patterns, cwd) do
    paths = Enum.flat_map(patterns, &expand(&1, cwd))

    not Enum.any?(paths, &String.contains?(&1, @not_undoable)) and Enum.all?(paths, &inside?(&1, cwd)) and
      Xeito.Undo.covers?(cwd, paths)
  end

  # A segment's paths with globs and any options allowed: read-only ones write nothing.
  defp confined_segment(segment) do
    if safe_segment?(segment),
      do: {:ok, []},
      else: with({:ok, [command | args]} <- glob_words(segment), do: confined_command(command, args))
  end

  defp confined_command(command, args) when command in @writers, do: writer_paths(args)
  defp confined_command("sed", args), do: command_paths("sed", Enum.map(args, &sed_long_option/1))
  defp confined_command("find", args), do: find_paths(args)
  defp confined_command(_command, _args), do: :error

  defp writer_paths(args) do
    {_options, paths} = Enum.split_with(args, &String.starts_with?(&1, "-"))
    if paths == [], do: :error, else: {:ok, paths}
  end

  # `find START… EXPRESSION -delete`: everything under the starting points may go.
  defp find_paths(args) do
    {starts, expression} = Enum.split_while(args, &(not String.starts_with?(&1, "-")))
    if "-delete" in expression, do: {:ok, if(starts == [], do: ["."], else: starts)}, else: :error
  end

  defp sed_long_option("--in-place"), do: "-i"
  defp sed_long_option("--in-place=" <> suffix), do: "-i" <> suffix
  defp sed_long_option("--regexp-extended"), do: "-E"
  defp sed_long_option(word), do: word

  defp dot_glob?(pattern), do: pattern |> Path.split() |> Enum.any?(&(String.starts_with?(&1, ".") and glob?(&1)))

  defp glob?(word), do: String.contains?(word, ["*", "?", "["])

  # The directories before a glob's first wildcard: what it matches later stays inside only if
  # they do (`out/*` through a symlink to elsewhere does not), whatever it matches now.
  defp glob_root_inside?(pattern, cwd) do
    case pattern |> Path.split() |> Enum.take_while(&(not glob?(&1))) do
      [] -> true
      root -> not glob?(pattern) or inside?(Path.join(root), cwd)
    end
  end

  # A glob becomes the workspace's paths it matches now; a plain path stays as it is.
  defp expand(pattern, cwd) do
    if glob?(pattern),
      do: cwd |> Path.join(pattern) |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, cwd)),
      else: [pattern]
  end

  # Shell words: plain ones without anything the shell would expand or interpret, or single-quoted.
  defp words(segment), do: shell_words(segment, &literal/1)

  # The same, globs (`*`, `?`, `[…]`) allowed.
  defp glob_words(segment), do: shell_words(segment, &glob_literal/1)

  defp shell_words(segment, literal) do
    ~r/(?:'[^']*'|[^\s'])+/
    |> Regex.scan(segment)
    |> Enum.map(fn [word] -> literal.(word) end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, word}, {:ok, acc} -> {:cont, {:ok, acc ++ [word]}}
      :error, _ -> {:halt, :error}
    end)
  end

  defp glob_literal(word) do
    cond do
      Regex.match?(~r/^'[^']*'$/, word) -> {:ok, String.slice(word, 1..-2//1)}
      Regex.match?(~r/[$`~{}\\"'()!#]/, word) -> :error
      true -> {:ok, word}
    end
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

  defp scan(chars, nil, cur, acc), do: plain(chars, cur, acc)
  defp scan(chars, "'", cur, acc), do: single_quoted(chars, cur, acc)
  defp scan(chars, "\"", cur, acc), do: double_quoted(chars, cur, acc)

  defp plain([], cur, acc), do: {:ok, Enum.reverse([segment(cur) | acc])}
  defp plain([quote | rest], cur, acc) when quote in ["'", "\""], do: scan(rest, quote, [quote | cur], acc)
  defp plain(["\\", c | rest], cur, acc), do: plain(rest, [c, "\\" | cur], acc)

  defp plain([c | rest] = chars, cur, acc) do
    cond do
      substitution_or_unsafe?(chars) -> :unsafe
      operator = operator(chars) -> operate(operator, cur, acc)
      true -> plain(rest, [c | cur], acc)
    end
  end

  # Inside single quotes nothing is special.
  defp single_quoted([], _cur, _acc), do: :unsafe
  defp single_quoted(["'" | rest], cur, acc), do: scan(rest, nil, ["'" | cur], acc)
  defp single_quoted([c | rest], cur, acc), do: single_quoted(rest, [c | cur], acc)

  # Inside double quotes a backslash escapes, and substitution still runs a command.
  defp double_quoted([], _cur, _acc), do: :unsafe
  defp double_quoted(["\"" | rest], cur, acc), do: scan(rest, nil, ["\"" | cur], acc)
  defp double_quoted(["\\", c | rest], cur, acc), do: double_quoted(rest, [c, "\\" | cur], acc)

  defp double_quoted([c | rest] = chars, cur, acc),
    do: if(substitution?(chars), do: :unsafe, else: double_quoted(rest, [c | cur], acc))

  # Command and process substitution, heredocs, and background jobs.
  defp substitution_or_unsafe?(chars), do: substitution?(chars) or unsafe_operator?(chars)

  defp substitution?(["`" | _]), do: true
  defp substitution?(["$", "(" | _]), do: true
  defp substitution?(_chars), do: false

  defp unsafe_operator?(["<", c | _]) when c in ["(", "<"], do: true
  defp unsafe_operator?(["&" | rest]), do: not match?([c | _] when c in ["&", ">"], rest)
  defp unsafe_operator?(_chars), do: false

  # Unquoted operators: `&&`, `||`, `|`, `;` and newlines separate commands; `&>` and `>` redirect.
  defp operator([op, op | rest]) when op in ["&", "|"], do: {:split, rest}
  defp operator([op | rest]) when op in ["|", ";", "\n"], do: {:split, rest}
  defp operator(["&", ">" | rest]), do: {:redirect, rest}
  defp operator([">" | rest]), do: {:redirect, rest}
  defp operator(_chars), do: nil

  defp operate({:split, rest}, cur, acc), do: split(rest, cur, acc)
  defp operate({:redirect, rest}, cur, acc), do: redirect(rest, cur, acc)

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
