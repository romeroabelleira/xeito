defmodule Xeito.Crap do
  @moduledoc """
  CRAP (Change Risk Anti-Patterns, Savoia and Evans) per function, as a `mix test --cover`
  tool: `complexity² × (1 − coverage)³ + complexity`, where complexity is cyclomatic
  complexity and coverage the share of the function's executable lines the tests ran.

  The suite fails when a function scores above the maximum (`test_coverage: [crap_max: n]` in
  `mix.exs`, default #{30}). Thirty is the threshold its authors proposed: a function may be as
  complex as 30 if it is fully tested, while an untested function reaches 30 at complexity 5.

  Complexity counts 1 for the function, plus one for each further clause, `if`/`unless`,
  `&&`/`||`/`and`/`or` (also in guards), each `case`/`cond`/`receive`/`fn` clause after the
  first, each `<-` of a `with` and each of its `else` clauses after the first, and each
  `rescue`/`catch` clause.

  It lives in `test/support`: a development tool, never part of the application.
  """

  alias Xeito.Source

  # `:cover` belongs to OTP's `tools` application, loaded when the tool starts.
  @compile {:no_warn_undefined, :cover}

  @defs [:def, :defp, :defmacro, :defmacrop]
  @default_max 30

  @type function_info :: %{
          module: String.t(),
          name: String.t(),
          first: pos_integer(),
          last: pos_integer(),
          complexity: pos_integer()
        }

  @doc "The CRAP score of a function with this complexity and coverage (0.0–1.0)."
  @spec score(pos_integer(), float()) :: float()
  def score(complexity, coverage), do: complexity * complexity * :math.pow(1 - coverage, 3) + complexity * 1.0

  @doc "The functions defined in a source file, with their line ranges and complexity."
  @spec functions(Path.t(), String.t()) :: [function_info()]
  def functions(path, source) do
    case Source.entries(path, source) do
      {:ok, entries} ->
        for %{kind: kind} = e <- entries, kind in @defs do
          %{
            module: e.module,
            name: e.name,
            first: e.first,
            last: e.last,
            complexity: e.clauses + Enum.sum(Enum.map(e.nodes, &decisions/1))
          }
        end

      {:error, _} ->
        []
    end
  end

  @doc "The share of executable lines in `first..last` that ran, from `[{line, calls}]`."
  @spec coverage([{pos_integer(), non_neg_integer()}], pos_integer(), pos_integer()) :: float()
  def coverage(lines, first, last) do
    case for {line, calls} <- lines, line in first..last, do: calls > 0 do
      [] -> 1.0
      ran -> Enum.count(ran, & &1) / length(ran)
    end
  end

  @doc """
  Checks scored functions against `max` and a baseline (`%{"Module.fun/arity" => score}`) of
  functions allowed to stay above it for now. The baseline may only shrink: `:ok`, or
  `{:error, problems}` listing functions over the maximum and not in the baseline (`:over`),
  baselined functions that got worse (`:worse`), and baseline entries no longer needed because the
  function is at or under the maximum or gone (`:stale`).
  """
  @spec gate([map()], number(), %{String.t() => number()}) :: :ok | {:error, keyword()}
  def gate(scored, max, baseline) do
    over = Enum.filter(scored, &(&1.crap > max and not Map.has_key?(baseline, key(&1))))
    worse = Enum.filter(scored, &(Map.has_key?(baseline, key(&1)) and &1.crap > baseline[key(&1)]))
    worst = Enum.reduce(scored, %{}, fn f, acc -> Map.update(acc, key(f), f.crap, &max(&1, f.crap)) end)
    stale = baseline |> Map.keys() |> Enum.filter(&(Map.get(worst, &1, 0) <= max)) |> Enum.sort()

    case Enum.reject([over: worst_first(over), worse: worst_first(worse), stale: stale], &(elem(&1, 1) == [])) do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  defp key(f), do: "#{f.module}.#{f.name}"
  defp worst_first(fs), do: Enum.sort_by(fs, & &1.crap, :desc)

  @doc "The scored functions above `max`, worst first."
  @spec offenders([map()], number()) :: [map()]
  def offenders(scored, max), do: scored |> Enum.filter(&(&1.crap > max)) |> Enum.sort_by(& &1.crap, :desc)

  # --- complexity ------------------------------------------------------------------------------

  defp decisions(node) do
    {_, count} = Macro.prewalk(node, 0, fn n, acc -> {n, acc + decision(n)} end)
    count
  end

  defp decision({op, _, [_, _]}) when op in [:&&, :||, :and, :or], do: 1
  defp decision({op, _, [_ | _]}) when op in [:if, :unless], do: 1
  defp decision({op, _, args}) when op in [:case, :cond, :receive] and is_list(args), do: arrows(List.last(args), :do) - 1
  defp decision({:fn, _, clauses}) when is_list(clauses), do: length(clauses) - 1
  defp decision({:with, _, args}) when is_list(args), do: with_decisions(args)

  defp decision({:try, _, [opts]}) when is_list(opts), do: arrows(opts, :rescue) + arrows(opts, :catch)

  defp decision(_node), do: 0

  defp with_decisions(args) do
    patterns = Enum.count(args, &match?({:<-, _, _}, &1))
    else_clauses = arrows(List.last(args), :else)
    patterns + max(else_clauses - 1, 0)
  end

  # The number of `->` clauses under `key` in a keyword list of blocks.
  defp arrows(opts, key) when is_list(opts) do
    case Keyword.get(opts, key) do
      clauses when is_list(clauses) -> Enum.count(clauses, &match?({:->, _, _}, &1))
      _ -> 0
    end
  end

  defp arrows(_opts, _key), do: 0

  # --- the `mix test --cover` tool ---------------------------------------------------------------

  @doc false
  def start(compile_path, opts) do
    Mix.ensure_application!(:tools)
    _ = :cover.start()
    _ = :cover.compile_beam_directory(String.to_charlist(compile_path))
    max = Keyword.get(opts, :crap_max, @default_max)
    baseline_path = Keyword.get(opts, :crap_baseline, "test/crap_baseline.exs")
    fn -> report(max, baseline_path) end
  end

  defp report(max, baseline_path) do
    scored = Enum.flat_map(:cover.modules(), &score_module/1)
    baseline = read_baseline(baseline_path)

    if System.get_env("XEITO_CRAP_WRITE_BASELINE") == "1", do: write_baseline(baseline_path, scored, max)

    IO.puts("\nCRAP (max #{max}; #{map_size(baseline)} baselined), highest:")
    for f <- scored |> worst_first() |> Enum.take(5), do: IO.puts("  #{format(f)}")

    # XEITO_CRAP_SHOW="Mod.fun/2,Mod.other/1": the lines of those functions no test ran.
    shown = "XEITO_CRAP_SHOW" |> System.get_env("") |> String.split(",", trim: true)
    for f <- scored, key(f) in shown, do: IO.puts("  uncovered in #{key(f)}: #{inspect(f.uncovered)}")

    case gate(scored, max, baseline) do
      :ok -> :ok
      {:error, problems} -> Mix.raise(explain(problems, max, baseline_path))
    end
  end

  defp explain(problems, max, baseline_path) do
    Enum.map_join(problems, "\n", fn
      {:over, fs} ->
        "Above the CRAP maximum of #{max}; add tests or simplify:\n" <> Enum.map_join(fs, "\n", &("  " <> format(&1)))

      {:worse, fs} ->
        "Worse than their baseline in #{baseline_path}:\n" <> Enum.map_join(fs, "\n", &("  " <> format(&1)))

      {:stale, keys} ->
        "No longer above the maximum (or gone); remove from #{baseline_path}:\n" <>
          Enum.map_join(keys, "\n", &("  " <> &1))
    end)
  end

  defp read_baseline(path) do
    if File.exists?(path), do: path |> Code.eval_file() |> elem(0), else: %{}
  end

  # Records today's offenders (rounded up), for adopting the gate on existing code; review the diff.
  defp write_baseline(path, scored, max) do
    entries =
      scored
      |> offenders(max)
      |> Enum.map(fn f -> {key(f), Float.ceil(f.crap, 1)} end)
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {k, v} -> "  #{inspect(k)} => #{v}" end)

    File.write!(path, """
    # Functions allowed above the CRAP maximum for now (Xeito.Crap). This list may only shrink:
    # a function may not get worse, and an entry must go once its function is at or under the
    # maximum. Add tests or simplify, then remove the entry.
    %{
    #{entries}
    }
    """)
  end

  defp format(f),
    do:
      "#{:erlang.float_to_binary(f.crap, decimals: 1)}  #{f.module}.#{f.name}  " <>
        "(complexity #{f.complexity}, coverage #{round(f.coverage * 100)}%, #{Path.relative_to_cwd(f.path)}:#{f.first})"

  defp scored(f, lines, source) do
    coverage = coverage(lines, f.first, f.last)
    uncovered = for {line, 0} <- lines, line in f.first..f.last, do: line
    Map.merge(f, %{path: source, coverage: coverage, crap: score(f.complexity, coverage), uncovered: uncovered})
  end

  # Functions of one cover-compiled module from the application's own sources (not test support).
  defp score_module(module) do
    source = to_string(module.module_info(:compile)[:source])
    name = inspect(module)

    with true <- File.exists?(source) and not String.contains?(source, "/test/"),
         {:ok, lines} <- :cover.analyse(module, :calls, :line) do
      lines = for {{^module, line}, calls} <- lines, line > 0, do: {line, calls}

      for f <- source |> File.read!() |> then(&functions(source, &1)), f.module == name, do: scored(f, lines, source)
    else
      _ -> []
    end
  end
end
