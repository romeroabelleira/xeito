defmodule Xeito.Decisions.Risk.Commands do
  @moduledoc """
  What each command `Xeito.Decisions.Risk` knows does, as data: one record per command, with its subcommands and the flags that change it.

  `effect/1` takes one segment of a command line (no `;`, `|` or redirects) and returns:

  - `:read`: it only reads, or it is the project's own build or test command (`trusted`: such a
    command runs code the repository supplies, safe on the premise that the user works in it);
  - `{:writes, paths}`: it writes these paths, as written, and nothing else;
  - `:exec`: it runs a program its text does not name (`rg --pre`, `find -exec`);
  - `:unknown`: anything else, including every command not in the table.

  A record is `%{class: class}` (`:read`, `:trusted`, `:write_args`: writes the paths among its
  arguments), with optional `cases` (a flag that changes the class: `:exec`, `:unknown`, or
  `:write_flag`, which writes the flag's value) and `subcommands`, or `%{handler: name}` for a
  command parsed by hand. Long options match by prefix, as getopt and git accept abbreviations;
  short ones inside a cluster (`-iz`). A write is only claimed for literal shell words.
  """

  @read %{class: :read}
  @trusted %{class: :trusted}
  @writer %{class: :write_args}

  # git diff, log and show: --output writes a file; an external diff or text conversion runs one.
  @git_output %{
    class: :read,
    cases: [
      %{long: ~w(ext-diff textconv), except: ~w(--text), class: :exec},
      %{long: ~w(output), class: :write_flag}
    ]
  }

  @table %{
    "ls" => @read,
    "cat" => @read,
    "head" => @read,
    "tail" => @read,
    "grep" => @read,
    "pwd" => @read,
    "echo" => @read,
    "wc" => @read,
    "which" => @read,
    "stat" => @read,
    "du" => @read,
    "df" => @read,
    "diff" => @read,
    "cut" => @read,
    "rg" => %{class: :read, cases: [%{long: ~w(pre search-zip hostname-bin), short: "z", class: :exec}]},
    "sort" => %{
      class: :read,
      cases: [%{long: ~w(compress-program), class: :exec}, %{long: ~w(output), short: "o", class: :write_flag}]
    },
    # -R writes 00Tree.html into each directory, paths the text does not name.
    "tree" => %{class: :read, cases: [%{short: "R", class: :unknown}, %{short: "o", class: :write_flag}]},
    "less" => %{class: :read, cases: [%{long: ~w(log-file LOG-FILE), short: "oO", class: :write_flag}]},
    # -C compiles a magic file next to its source.
    "file" => %{class: :read, cases: [%{long: ~w(compile), short: "C", class: :unknown}]},
    "find" => %{
      class: :read,
      cases: [
        %{words: ~w(-delete -exec -execdir -ok -okdir), class: :exec},
        %{words: ~w(-fprint -fprint0 -fprintf -fls), class: :unknown}
      ]
    },
    "uniq" => %{handler: :uniq},
    "sed" => %{handler: :sed},
    "cd" => %{handler: :cd},
    "xargs" => %{handler: :xargs},
    "touch" => @writer,
    "mkdir" => @writer,
    "rm" => @writer,
    "mv" => @writer,
    "cp" => @writer,
    "tee" => @writer,
    "git" => %{
      subcommands: %{
        "status" => @read,
        "blame" => @read,
        "diff" => @git_output,
        "log" => @git_output,
        "show" => @git_output,
        "branch" => %{handler: :git_branch}
      }
    },
    "mix" => %{subcommands: Map.new(~w(test compile format deps.get credo), &{&1, @trusted})},
    "npm" => %{subcommands: %{"test" => @trusted, "run" => %{subcommands: %{"test" => @trusted, "lint" => @trusted}}}},
    "pytest" => @trusted,
    "python" => %{subcommands: %{"-m" => %{subcommands: %{"pytest" => @trusted}}}},
    "python3" => %{subcommands: %{"-m" => %{subcommands: %{"pytest" => @trusted}}}},
    "cargo" => %{subcommands: Map.new(~w(test build check), &{&1, @trusted})},
    "go" => %{subcommands: Map.new(~w(test build), &{&1, @trusted})},
    "make" => %{subcommands: %{"test" => @trusted}},
    "bundle" => %{subcommands: %{"exec" => %{subcommands: %{"rspec" => @trusted}}}}
  }

  @type effect :: :read | {:writes, [String.t()]} | :exec | :unknown

  @doc "The table: command → record."
  @spec table() :: %{String.t() => map()}
  def table, do: @table

  @doc "What one segment of a command line does."
  @spec effect(String.t()) :: effect()
  def effect(segment) do
    case arguments(segment) do
      [command | args] -> resolve(@table[command], args, segment)
      [] -> :unknown
    end
  end

  @doc "Whether `command` writes the paths among its arguments (`rm`, `cp`, …)."
  @spec writer?(String.t()) :: boolean()
  def writer?(command), do: @table[command] == @writer

  # The segment's words with the shell's quotes dropped: enough to read flags.
  defp arguments(segment),
    do: segment |> String.split(~r/\s+/, trim: true) |> Enum.map(&String.replace(&1, ~r/['"\\]/, ""))

  defp resolve(nil, _args, _segment), do: :unknown

  defp resolve(%{subcommands: subcommands}, [sub | args], segment) when is_map_key(subcommands, sub),
    do: resolve(subcommands[sub], args, segment)

  defp resolve(%{subcommands: _}, _args, _segment), do: :unknown
  defp resolve(%{handler: handler}, args, segment), do: handle(handler, args, segment)

  defp resolve(%{class: class} = record, args, segment),
    do: by_case(Enum.find(Map.get(record, :cases, []), &applies?(&1, args)), class, segment)

  defp by_case(nil, class, segment), do: base(class, segment)
  defp by_case(%{class: :write_flag} = flag, _class, segment), do: flag_write(flag, segment)
  defp by_case(%{class: class}, _class, _segment), do: class

  defp base(class, _segment) when class in [:read, :trusted], do: :read
  defp base(:write_args, segment), do: write_args(segment)

  defp applies?(%{words: words}, args), do: Enum.any?(args, &(&1 in words))

  defp applies?(flag, args),
    do:
      Enum.any?(
        args,
        &((long?(&1, Map.get(flag, :long, [])) and &1 not in Map.get(flag, :except, [])) or
            short?(&1, Map.get(flag, :short, "")))
      )

  # `--name` or `--name=value`, `name` a prefix of one of `names`.
  defp long?("--" <> option, names) do
    name = option |> String.split("=", parts: 2) |> hd()
    name != "" and Enum.any?(names, &String.starts_with?(&1, name))
  end

  defp long?(_arg, _names), do: false

  # A cluster of short options (`-iz`) holding any of `letters`.
  defp short?("-" <> cluster, letters),
    do: not String.starts_with?(cluster, "-") and String.contains?(cluster, String.graphemes(letters))

  defp short?(_arg, _letters), do: false

  # --- writes -----------------------------------------------------------------------------

  # `rm -rf a b`: every argument that is not an option is written; only short options, as a long
  # one may take a path as its value.
  defp write_args(segment) do
    with {:ok, [_command | args]} <- words(segment, :literal),
         {options, [_ | _] = paths} <- Enum.split_with(args, &String.starts_with?(&1, "-")),
         true <- Enum.all?(options, &Regex.match?(~r/^-[a-zA-Z]+$/, &1)) do
      {:writes, paths}
    else
      _ -> :unknown
    end
  end

  # The value of every use of the flag: `-o FILE`, `-oFILE`, `-uo FILE`, `--output=FILE`, `--output FILE`.
  defp flag_write(flag, segment) do
    with {:ok, words} <- words(segment, :literal),
         {:ok, [_ | _] = paths} <- values(words, Map.get(flag, :long, []), Map.get(flag, :short, ""), []) do
      {:writes, paths}
    else
      _ -> :unknown
    end
  end

  defp values([], _long, _short, acc), do: {:ok, Enum.reverse(acc)}
  defp values([word | rest], long, short, acc), do: word |> flag_value(long, short) |> collect(rest, {long, short}, acc)

  # What one word says of the flag: nothing, its value, or that the next word is the value.
  defp flag_value("--" <> option = word, long, _short),
    do: long_value(long?(word, long), String.split(option, "=", parts: 2))

  defp flag_value("-" <> cluster, _long, short) when cluster != "", do: short_flag(short_value(cluster, short))
  defp flag_value(_word, _long, _short), do: :none

  defp long_value(true, [_name, value]), do: {:value, value}
  defp long_value(true, [_name]), do: :next
  defp long_value(false, _parts), do: :none

  defp short_flag(nil), do: :none
  defp short_flag(""), do: :next
  defp short_flag(value), do: {:value, value}

  defp collect(:none, rest, {long, short}, acc), do: values(rest, long, short, acc)
  defp collect({:value, value}, rest, {long, short}, acc), do: values(rest, long, short, [value | acc])
  defp collect(:next, [value | rest], {long, short}, acc), do: values(rest, long, short, [value | acc])
  defp collect(:next, [], _flag, _acc), do: :error

  # In `-uoFILE` the value is what follows the flag's letter; `""` when the next word holds it.
  defp short_value(_cluster, ""), do: nil

  defp short_value(cluster, short) do
    case :binary.match(cluster, String.graphemes(short)) do
      {at, 1} -> binary_part(cluster, at + 1, byte_size(cluster) - at - 1)
      :nomatch -> nil
    end
  end

  # --- commands parsed by hand ------------------------------------------------------------

  # `uniq INPUT OUTPUT` writes OUTPUT. An option's value may look like a path, so every word but
  # the first that is not an option counts as written: more than it writes, never less.
  defp handle(:uniq, args, segment), do: uniq(Enum.reject(args, &String.starts_with?(&1, "-")), segment)
  defp handle(:git_branch, args, _segment), do: read_if(branch_listing?(args, Enum.any?(args, &(&1 in ["-l", "--list"]))))
  defp handle(:sed, _args, segment), do: sed(segment)
  defp handle(:cd, _args, segment), do: read_if(into_subdirectory?(segment))
  defp handle(:xargs, _args, segment), do: xargs(segment)

  defp read_if(true), do: :read
  defp read_if(false), do: :unknown

  defp uniq([_input, _ | _], segment), do: uniq_writes(segment)
  defp uniq(_names, _segment), do: :read

  defp sed(segment) do
    if Regex.match?(~r/^sed\s+-n\s+'?\d+(,(\d+|\$))?p'?(\s+[^\s-][^\s;]*)*$/, segment),
      do: :read,
      else: sed_effect(segment)
  end

  # `xargs` feeding a read-only command (`find … | xargs grep -l x`) is as safe as that command.
  defp xargs(segment) do
    rest = Regex.replace(~r/^xargs(\s+-(0|r|t|[nLP]\s*\d+|I\s*\S+|d\s*\S+))*\s+/, segment, "")
    read_if(rest != segment and effect(rest) == :read)
  end

  defp uniq_writes(segment) do
    case words(segment, :literal) do
      {:ok, [_uniq | args]} -> {:writes, args |> Enum.reject(&String.starts_with?(&1, "-")) |> tl()}
      :error -> :unknown
    end
  end

  defp sed_effect(segment) do
    with {:ok, [_sed | args]} <- words(segment, :literal), {:ok, files} <- sed_writes(args) do
      {:writes, files}
    else
      _ -> :unknown
    end
  end

  defp into_subdirectory?(segment),
    do: Regex.match?(~r/^cd\s+[\w.\/-]+$/, segment) and not Regex.match?(~r/^cd\s+(\/|~|-|\.\.)|\.\./, segment)

  # `--abbrev` and `--color` take a value only as `--abbrev=7`: in `--abbrev 7`, 7 names a new branch.
  @branch_options ~w(--all --remotes --list --verbose --show-current --color --no-color --column --no-column --ignore-case --omit-empty --abbrev --no-abbrev)
  @branch_valued ~w(--contains --no-contains --merged --no-merged --points-at --sort --format)

  # Only the forms of `git branch` that list: known options, and patterns after `--list`.
  defp branch_listing?([], _list), do: true
  defp branch_listing?([option, _value | rest], list) when option in @branch_valued, do: branch_listing?(rest, list)
  defp branch_listing?(["-" <> _ = option | rest], list), do: branch_option?(option) and branch_listing?(rest, list)
  defp branch_listing?([_pattern | rest], list), do: list and branch_listing?(rest, list)

  defp branch_option?("--" <> _ = option),
    do: (option |> String.split("=", parts: 2) |> hd()) in (@branch_options ++ @branch_valued)

  defp branch_option?("-" <> letters), do: Regex.match?(~r/^[arlvi]+$/, letters)

  @doc """
  The files `sed -i[SUFFIX] [-i ''] [-E|-r] [-e SCRIPT] [SCRIPT] FILE...` rewrites, given its
  arguments, when its script is one plain substitution (no `w` or `e` flag); else `:error`.
  """
  @spec sed_writes([String.t()]) :: {:ok, [String.t()]} | :error
  def sed_writes(args), do: args |> sed_options(%{in_place: false, script: nil}) |> sed_files()

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

  # --- shell words --------------------------------------------------------------------------

  @doc """
  The segment's shell words, `{:ok, words}` when each is plain (nothing the shell would expand or
  interpret) or single-quoted, else `:error`; with `:glob`, globs (`*`, `?`, `[…]`) are allowed.
  """
  @spec words(String.t(), :literal | :glob) :: {:ok, [String.t()]} | :error
  def words(segment, kind) do
    ~r/(?:'[^']*'|[^\s'])+/
    |> Regex.scan(segment)
    |> Enum.map(fn [word] -> literal(word, kind) end)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, word}, {:ok, acc} -> {:cont, {:ok, acc ++ [word]}}
      :error, _ -> {:halt, :error}
    end)
  end

  defp literal(word, kind) do
    cond do
      Regex.match?(~r/^'[^']*'$/, word) -> {:ok, String.slice(word, 1..-2//1)}
      Regex.match?(special(kind), word) -> :error
      true -> {:ok, word}
    end
  end

  defp special(:literal), do: ~r/[$`~*?\[\]{}\\"'()!#]/
  defp special(:glob), do: ~r/[$`~{}\\"'()!#]/
end
