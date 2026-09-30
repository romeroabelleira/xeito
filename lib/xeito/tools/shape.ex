defmodule Xeito.Tools.Shape do
  @moduledoc """
  Shapes tool output before a model reads it (P4b, `docs/implementation-plan.md`): the model
  gets what it needs to act on, not every byte a command printed. A chat run resends every
  earlier tool output on every step, so long outputs cost many times over.

    * **Shell output**: terminal escape codes and progress redraws are removed, runs of repeated
      or similar lines are collapsed (`… 37 similar lines`), and long output keeps its first and
      last lines.
    * **Test and compiler output** (recognised by its shape: ExUnit, `mix compile`, pytest,
      cargo, go test): failures, errors, warnings and the summary are kept.
    * **Search results** (`grep`, `rg`): grouped by file, capped per file and in total.
    * **Large file reads**, by purpose: dependency sources and generated files (`deps/`,
      `node_modules/`, `_build/`, …), which a model reads to learn an API, become the outline
      (Elixir) or the first part past 400 lines. The project's own files, which it reads to edit
      them, stay whole up to 2,000 lines: shaping them made the model page through files one
      step at a time (bench 4 §5).

  Shaping runs in the effect runner (`Xeito.Effects.Local`), which adds the text as `:shaped`
  to the result, next to the full output. Both are logged, so a replay shows the model exactly
  what it saw, and the original stays retrievable: shaped text ends with how to read it back
  (`read` with `result:` and the effect's id). Output that shaping would barely shorten is left
  alone.
  """

  alias Xeito.{Effect, Source}

  # Shell output longer than this keeps its first @head and last @tail lines.
  @max_lines 120
  @head 60
  @tail 40
  @max_line_chars 400
  # Test and compiler output is condensed only past this many lines.
  @min_structured 40
  # Search results: matches kept per file, and files kept.
  @grep_per_file 8
  @grep_files 30
  # Reads past this many lines are shown as an outline or their first part: dependency and
  # generated sources soon, the project's own files only when very long.
  @max_read_lines 400
  @max_project_read_lines 2_000
  @third_party ~w(deps node_modules _build vendor target dist build .venv venv __pycache__)
  @read_head 250
  @elixir_read_head 120

  @doc "The result, with `:shaped` text added when shaping shortens it enough to matter."
  @spec shape(Effect.t(), map()) :: map()
  def shape(%Effect{kind: :bash, args: args} = effect, %{output: output} = result)
      when is_binary(output) do
    {text, before, now} = bash(args.cmd, output)

    if shorter?(output, text),
      do:
        Map.put(
          result,
          :shaped,
          "exit status #{result.exit_status}\n" <> text <> footer(effect, before, now)
        ),
      else: result
  end

  def shape(%Effect{kind: :read, args: args}, %{ok: true, content: content} = result)
      when is_binary(content) do
    if explicit?(args), do: result, else: read(args.path, content, result)
  end

  def shape(_effect, result), do: result

  # A read of an outline, a symbol, a line range or a stored result is exactly what was asked for.
  defp explicit?(args),
    do: Enum.any?([:outline, :symbol, :lines, :result], &Map.has_key?(args, &1))

  defp shorter?(original, shaped), do: byte_size(shaped) < byte_size(original) * 0.8

  defp footer(effect, before, now),
    do: "\n[shaped: #{before} → #{now} lines; full output: read with result: \"#{ref(effect)}\"]"

  # The effect's full id: it stays valid in later turns (whose runs have other ids).
  defp ref(%Effect{id: id}) when is_binary(id), do: id
  defp ref(_effect), do: "?"

  # --- shell output --------------------------------------------------------------------------

  @doc false
  @spec bash(String.t(), String.t()) :: {String.t(), non_neg_integer(), non_neg_integer()}
  def bash(cmd, output) do
    lines = output |> clean() |> String.split("\n") |> drop_trailing_blank()

    shaped =
      cond do
        search?(cmd, lines) -> grep(lines)
        length(lines) > @min_structured and structured?(lines) -> structured(lines)
        true -> lines
      end
      |> collapse()
      |> head_tail()
      |> Enum.map(&truncate/1)

    {Enum.join(shaped, "\n"), length(lines), length(shaped)}
  end

  # Escape codes (colours, cursor moves) and progress redraws: a line rewritten with \r keeps
  # only its final state.
  defp clean(output) do
    output
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map_join("\n", fn line -> line |> String.split("\r") |> List.last() end)
  end

  defp drop_trailing_blank(lines),
    do: lines |> Enum.reverse() |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()

  defp truncate(line) do
    if String.length(line) > @max_line_chars,
      do: String.slice(line, 0, @max_line_chars) <> " …",
      else: line
  end

  # Runs of the same line, or of lines that differ only in numbers (progress, timings, ids),
  # become the first two, a count, and the last one.
  defp collapse(lines) do
    lines
    |> Enum.chunk_by(&String.replace(&1, ~r/\d+/, "#"))
    |> Enum.flat_map(fn
      [first, second | rest] when length(rest) >= 2 ->
        [first, second, "… #{length(rest) - 1} similar lines", List.last(rest)]

      run ->
        run
    end)
  end

  defp head_tail(lines) when length(lines) > @max_lines do
    skipped = length(lines) - @head - @tail
    Enum.take(lines, @head) ++ ["… #{skipped} lines …"] ++ Enum.take(lines, -@tail)
  end

  defp head_tail(lines), do: lines

  # --- search results ------------------------------------------------------------------------

  defp search?(cmd, lines) do
    Regex.match?(~r/(^|[|;&]\s*)(grep|rg|git grep)\b/, String.trim(cmd)) and length(lines) > 20 and
      Enum.count(lines, &match_line/1) * 2 >= length(lines)
  end

  # `path:line:text` or `path:text`.
  defp match_line(line) do
    case Regex.run(~r/^([^:\s][^:]*?):(\d+:)?(.*)$/, line) do
      [_, path, _, text] when path != "" ->
        # `grep -n` on one file prints `12:text`: a line number, not a path.
        if Regex.match?(~r/^\d+$/, path), do: nil, else: {path, line_prefix(line, path), text}

      _ ->
        nil
    end
  end

  defp line_prefix(line, path) do
    case Regex.run(~r/^#{Regex.escape(path)}:(\d+):/, line) do
      [_, n] -> n <> ": "
      nil -> ""
    end
  end

  defp grep(lines) do
    groups =
      lines
      |> Enum.map(&match_line/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.chunk_by(&elem(&1, 0))

    shown = Enum.take(groups, @grep_files)

    body =
      Enum.flat_map(shown, fn [{path, _, _} | _] = matches ->
        kept = Enum.take(matches, @grep_per_file)
        more = length(matches) - length(kept)

        ["#{path} (#{length(matches)} #{plural(length(matches), "match")})"] ++
          Enum.map(kept, fn {_, n, text} -> "  #{n}#{String.trim(text)}" end) ++
          if(more > 0, do: ["  … #{more} more"], else: [])
      end)

    rest = Enum.drop(groups, @grep_files)

    if rest == [],
      do: body,
      else:
        body ++
          ["… #{length(rest)} more files, #{rest |> Enum.map(&length/1) |> Enum.sum()} matches"]
  end

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "es"

  # --- test and compiler output --------------------------------------------------------------

  defp structured?(lines), do: Enum.any?(lines, &(summary?(&1) or problem?(&1)))

  defp summary?(line),
    do:
      Regex.match?(
        ~r/^\s*(Finished in |Result: |\d+ (doctests?|tests?|properties|examples?)[,.]|=+ .*(passed|failed)|test result:|ok\s+\S+\s+[\d.]+s|FAIL\s+\S+|Randomized with seed)/,
        line
      )

  defp problem?(line),
    do:
      Regex.match?(
        ~r/^\s*(\d+\) test |\*\* \(|error(\[\w+\])?:|warning:|FAILED|FAIL:|ERROR|Traceback|panicked at|--- FAIL)/,
        line
      )

  # Problems with the lines that follow them (up to the next problem, a blank line after some
  # context, or 30 lines), then the summary lines.
  defp structured(lines) do
    indexed = Enum.with_index(lines)
    starts = for {line, i} <- indexed, problem?(line), do: i

    blocks =
      starts
      |> Enum.zip(Enum.drop(starts, 1) ++ [length(lines)])
      |> Enum.map(fn {from, next} -> Enum.slice(lines, from, min(next - from, 30)) end)
      |> Enum.map(&trim_block/1)

    summary = for {line, _} <- indexed, summary?(line), do: line

    case blocks do
      [] -> Enum.take(lines, 5) ++ ["… (no failures, errors or warnings found)"] ++ summary
      blocks -> Enum.intersperse(blocks, [""]) |> List.flatten() |> Kernel.++(["" | summary])
    end
  end

  # A block ends at a blank line followed by an unindented line (the next section).
  defp trim_block([first | rest]) do
    kept =
      rest
      |> Enum.chunk_every(2, 1, [:end])
      |> Enum.take_while(fn
        ["", next] when is_binary(next) -> String.starts_with?(next, " ")
        _ -> true
      end)
      |> Enum.map(&hd/1)

    [first | kept] |> drop_trailing_blank()
  end

  # --- file reads ----------------------------------------------------------------------------

  defp read_limit(path) do
    if path |> Path.split() |> Enum.any?(&(&1 in @third_party)),
      do: @max_read_lines,
      else: @max_project_read_lines
  end

  defp read(path, content, result) do
    lines = String.split(content, "\n")
    total = length(lines)

    if total <= read_limit(path) do
      result
    else
      shaped =
        case Source.outline(path, content) do
          {:ok, outline} ->
            head = Enum.take(lines, @elixir_read_head)

            outline <>
              "\n\nFirst #{@elixir_read_head} lines:\n" <>
              Enum.join(head, "\n") <>
              "\n[shaped: #{total} lines; read a definition with symbol, or a range with lines: \"#{@elixir_read_head + 1}-#{@elixir_read_head + 300}\"]"

          {:error, _} ->
            Enum.join(Enum.take(lines, @read_head), "\n") <>
              "\n[shaped: first #{@read_head} of #{total} lines; read more with lines: \"#{@read_head + 1}-#{@read_head + 300}\"]"
        end

      Map.put(result, :shaped, shaped)
    end
  end
end
