defmodule Xeito.Decisions.Risk do
  @moduledoc """
  The decision whether a proposed shell command is safe to run in the workspace: `:safe`, `:review` or `:forbidden`.

  Monotonic: rules are authoritative when they fire; otherwise the result is at least `:review`,
  and a model can only raise it to `:forbidden`. It never goes to a remote tier.
  """

  use Xeito.Decision, version: "2"

  alias Xeito.Decisions.Risk.Commands

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
  # Writes the rules cannot prove from the text, but undo can take back.
  rule :undoable

  severity [:safe, :review, :forbidden], floor: :review
  policy remote: :forbidden

  # Small tiers failed the zero-shot gate; they decide again once they pass.
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

  # Never safe by rule, whatever the command: forcing, and secrets.
  @excluded ["--force", ".env", ".ssh", "credentials", ".netrc"]

  @doc false
  def classify(%{command: command} = input) do
    cond do
      forbidden?(command) -> :forbidden
      all_segments_safe?(command) -> :safe
      writes_inside?(command, Map.get(input, :cwd) || "") -> :safe
      true -> nil
    end
  end

  @doc """
  Whether `command` may run again with no further effect, as after a crash: every part is safe by
  rule without writing (reading, building, testing), and nothing is forbidden. A write inside the
  workspace is safe to run once, not twice.
  """
  @spec repeatable?(String.t()) :: boolean()
  def repeatable?(command), do: not forbidden?(command) and all_segments_safe?(command)

  # Each part counts as well as the whole, so a command after a forbidden one hides nothing
  # (`rm -rf ~/ ; ls`). The split ignores quotes on purpose: a false match only blocks.
  defp forbidden?(command) do
    parts = [command | String.split(command, ~r/;|&&|\|\||\||\n/)]
    Enum.any?(parts, fn part -> Enum.any?(forbidden_patterns(), &Regex.match?(&1, part)) end)
  end

  defp all_segments_safe?(command) do
    case segments(command) do
      {:ok, segments} -> segments |> Enum.reject(&(&1 == "")) |> Enum.all?(&safe_segment?/1)
      :unsafe -> false
    end
  end

  # Read-only by the command table (`Xeito.Decisions.Risk.Commands`), and nothing excluded.
  defp safe_segment?(segment), do: not String.contains?(segment, @excluded) and Commands.effect(segment) == :read

  # --- writes inside the workspace ---------------------------------------------------------
  # Safe only if every write is visible in the text, every path is a literal word inside the
  # workspace after symlinks (not its root, not .git, not a protected dir), and an undo snapshot
  # would hold every path. Anything else goes to review.

  # Without a workspace, `Xeito.Undo.covers?/3` covers nothing.
  defp writes_inside?(command, cwd) do
    with false <- String.contains?(command, @excluded), {:ok, paths} <- written_paths(command) do
      Enum.all?(paths, &inside?(&1, cwd)) and Xeito.Undo.covers?(cwd, paths)
    else
      _ -> false
    end
  end

  @doc """
  The paths `command` writes, as written, redirects first: `{:ok, paths}` when every one is a
  literal word the rules can name, else `:error`.
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
    case {String.contains?(segment, @excluded), Commands.effect(segment)} do
      {false, :read} -> {:ok, []}
      {_, {:writes, paths}} -> {:ok, paths}
      _ -> :error
    end
  end

  # --- writes undo can take back (undo stage 3) ---------------------------------------------
  # Globs, unknown options and `find … -delete` are safe when every expanded path is inside and a
  # snapshot covers it. Secrets, `-exec` and dot-globs (they match `.git`, `.env`) still go to review.

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
      else: with({:ok, [command | args]} <- Commands.words(segment, :glob), do: confined_command(command, args))
  end

  defp confined_command("sed", args), do: Commands.sed_writes(Enum.map(args, &sed_long_option/1))
  defp confined_command("find", args), do: find_paths(args)
  defp confined_command(command, args), do: if(Commands.writer?(command), do: writer_paths(args), else: :error)

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

  # A glob stays inside later only if its leading directories do (`out/*` via an outside symlink does not).
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
  # Splits at unquoted `|`, `||`, `&&`, `;` and newlines. Strict on purpose: `:unsafe` for substitution,
  # heredocs, background jobs and unbalanced quotes. A redirect to a file is a write: `parse/1` returns it.

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

  # After `>`, `>>`, `N>` or `&>`: `/dev/null`, a stream, or a plain-word file recorded as a write.
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
