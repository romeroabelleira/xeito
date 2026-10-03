defmodule Xeito.Mutate do
  @moduledoc """
  Mutation testing (`mix xeito.mutate`): change one small thing in the code, run its tests, and
  see whether they notice. A mutant the tests notice is *killed*; one they miss *survives*, and
  points at behaviour no test pins down. Coverage only says a line ran; this says a test would
  fail if the line were wrong.

  Mutations, one place at a time:

    * comparisons negated (`==` → `!=`, `>` → `<=`), and ordering ones also moved across the
      boundary (`>` → `>=`), the usual off-by-one
    * `and`/`or` and `&&`/`||` swapped, `not x` and `!x` → `x`, `in` → `not in`
    * `if` ↔ `unless`, `+` ↔ `-`

  Module attributes (specs, docs, constants) are left alone. Each mutant is compiled in memory
  and loaded over the real module, so the tests run in the same VM without recompiling the
  project; the original is loaded again afterwards.

  It lives in `test/support`: a development tool, never part of the application.
  """

  @type mutant :: %{
          path: Path.t(),
          line: pos_integer() | nil,
          description: String.t(),
          ast: Macro.t(),
          original: Macro.t()
        }

  @negations %{==: :!=, !=: :==, ===: :!==, !==: :===, <: :>=, >=: :<, >: :<=, <=: :>}
  @boundaries %{<: :<=, <=: :<, >: :>=, >=: :>}
  @swaps %{and: :or, or: :and, &&: :||, ||: :&&, +: :-, -: :+}
  # Attributes that document or type the code rather than being part of it.
  @not_code [:doc, :moduledoc, :typedoc, :spec, :type, :typep, :opaque, :callback, :macrocallback, :impl, :behaviour]

  @doc """
  The mutants of a source file, in source order. Option `lines: [Range.t()]` keeps only the
  mutants on those lines.
  """
  @spec mutants(String.t(), Path.t(), keyword()) :: [mutant()]
  def mutants(source, path, opts \\ []) do
    ast = Code.string_to_quoted!(source, file: path)
    {_, %{sites: sites}} = walk(ast, %{n: 0, target: nil, sites: [], line: 1})
    keep = Keyword.get(opts, :lines)

    for {id, line, description} <- Enum.reverse(sites), keep == nil or Enum.any?(keep, &(line in &1)) do
      {mutated, _} = walk(ast, %{n: 0, target: id, sites: [], line: 1})
      %{path: path, line: line, description: description, ast: mutated, original: ast}
    end
  end

  @doc """
  Loads each mutant in place of its module, runs `run_tests` (which returns ExUnit's result map)
  and records the mutant as `:killed` (a test failed), `:survived` or `:invalid` (it does not
  compile). The original code is loaded again at the end.
  """
  @spec check([mutant()], (-> %{:failures => non_neg_integer(), optional(atom()) => term()})) :: [map()]
  def check(mutants, run_tests) do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Enum.map(mutants, &Map.put(&1, :status, status(&1, run_tests)))
    after
      mutants |> Enum.map(& &1.original) |> Enum.uniq() |> Enum.each(&load/1)
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  defp status(mutant, run_tests) do
    case load(mutant.ast) do
      :ok -> if run_tests.().failures > 0, do: :killed, else: :survived
      :error -> :invalid
    end
  end

  # Compiles quietly: a mutant often draws warnings (a comparison that is always true).
  defp load(ast) do
    {result, _diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_quoted(ast)
          :ok
        rescue
          _ -> :error
        end
      end)

    result
  end

  @doc "Counts by status; the score is the share of compiling mutants the tests killed."
  @spec summary([map()]) :: %{killed: integer(), survived: integer(), invalid: integer(), score: float()}
  def summary(results) do
    counts = Enum.frequencies_by(results, & &1.status)
    killed = Map.get(counts, :killed, 0)
    survived = Map.get(counts, :survived, 0)
    score = if killed + survived == 0, do: 1.0, else: killed / (killed + survived)
    %{killed: killed, survived: survived, invalid: Map.get(counts, :invalid, 0), score: score}
  end

  @doc "One line for a result: where, what changed, and the source line."
  @spec format(map(), [String.t()]) :: String.t()
  def format(result, source_lines),
    do:
      "#{result.path}:#{result.line}  #{result.description}  #{source_lines |> Enum.at(result.line - 1, "") |> String.trim()}"

  @doc """
  What to mutate: `{source, section or nil, test files}` for the given `paths` and `tests` and the
  configuration (`test/mutate.exs`): `%{source => [test file]}`, or
  `%{source => [tests: [...], section: name]}` for one section of it. Without paths, every
  configured source; without tests, each source's configured ones (an empty list means: find
  them). Each source runs only its own tests, so the configuration says what covers it.
  """
  @spec plan([Path.t()], [Path.t()], map()) :: [{Path.t(), String.t() | nil, [Path.t()]}]
  def plan([], [], config), do: config |> Map.keys() |> Enum.sort() |> plan([], config)

  def plan(paths, tests, config) do
    for path <- paths do
      entry = entry(config, path)
      {path, entry[:section], if(tests == [], do: Enum.sort(entry[:tests] || []), else: tests)}
    end
  end

  @doc """
  Splits a plan into what to mutate and the sources skipped: an entry with
  `only_when_changed: true` is mutated only when it or one of its tests is among `changed`
  (paths), or when what changed is unknown (`:all`).
  """
  @spec select(list(), map(), [Path.t()] | :all) :: {list(), [Path.t()]}
  def select(plan, _config, :all), do: {plan, []}

  def select(plan, config, changed) do
    {run, skipped} =
      Enum.split_with(plan, fn {path, _section, tests} ->
        not Keyword.get(entry(config, path), :only_when_changed, false) or Enum.any?([path | tests], &(&1 in changed))
      end)

    {run, Enum.map(skipped, &elem(&1, 0))}
  end

  defp entry(config, path) do
    case Map.get(config, path, []) do
      [{:tests, _} | _] = entry -> entry
      [{:section, _} | _] = entry -> entry
      tests -> [tests: tests]
    end
  end

  @doc """
  The lines of a section: from its marker comment (`# --- name ---`) to the line before the next
  marker, or the end of the file.
  """
  @spec section_lines(String.t(), String.t()) :: Range.t()
  def section_lines(source, name) do
    lines = String.split(source, "\n")
    markers = for {line, n} <- Enum.with_index(lines, 1), marker = marker(line), do: {marker, n}

    case Enum.split_while(markers, fn {marker, _} -> marker != name end) do
      {_, [{_, first} | rest]} -> first..(if(rest == [], do: length(lines) + 1, else: elem(hd(rest), 1)) - 1)
      {_, []} -> raise ArgumentError, "no section #{inspect(name)} (a `# --- #{name} ---` comment)"
    end
  end

  defp marker(line) do
    case Regex.run(~r/^\s*# --- (.+?) -*\s*$/, line) do
      [_, name] -> name
      nil -> nil
    end
  end

  @doc "The modules a source file defines, by full name (nested modules included)."
  @spec modules(String.t()) :: [String.t()]
  def modules(source), do: source |> Code.string_to_quoted!() |> defined(nil) |> Enum.map(&inspect/1)

  defp defined({:defmodule, _, [{:__aliases__, _, parts}, [do: body]]}, parent) do
    module = if parent, do: Module.concat([parent | parts]), else: Module.concat(parts)
    [module | defined(body, module)]
  end

  defp defined({:__block__, _, nodes}, parent), do: Enum.flat_map(nodes, &defined(&1, parent))
  defp defined(_node, _parent), do: []

  @doc """
  The test files (`[{path, content}]`) that use one of the modules: by full name, or aliased
  with others from its namespace (`alias Xeito.Decisions.{Intent, Risk}`).
  """
  @spec tests_for([String.t()], [{Path.t(), String.t()}]) :: [Path.t()]
  def tests_for(modules, files) do
    for {path, content} <- files, Enum.any?(modules, &uses?(content, &1)), do: path
  end

  defp uses?(content, module) do
    {namespace, [last]} = module |> String.split(".") |> Enum.split(-1)
    multi = ~r/#{Regex.escape(Enum.join(namespace, "."))}\.\{[^}]*\b#{Regex.escape(last)}\b/
    String.contains?(content, module) or (namespace != [] and Regex.match?(multi, content))
  end

  # --- the walk ----------------------------------------------------------------------------------

  # Counts the mutation sites (each variant has an id) and applies the one with `target`'s id.
  # Children are walked first, so a mutated node is built from its (unchanged) children.
  defp walk({:@, _, [{name, _, _}]} = node, acc) when name in @not_code, do: {node, acc}

  defp walk({form, meta, args} = node, acc) when is_list(meta) do
    acc = %{acc | line: meta[:line] || acc.line}

    site(node, acc, fn acc ->
      {form, acc} = walk(form, acc)
      {args, acc} = if is_list(args), do: Enum.map_reduce(args, acc, &walk/2), else: {args, acc}
      {{form, meta, args}, acc}
    end)
  end

  defp walk(list, acc) when is_list(list), do: site(list, acc, &Enum.map_reduce(list, &1, fn x, a -> walk(x, a) end))

  defp walk({a, b}, acc) do
    {a, acc} = walk(a, acc)
    {b, acc} = walk(b, acc)
    {{a, b}, acc}
  end

  defp walk(literal, acc), do: {literal, acc}

  defp site(node, acc, walk_children) do
    variants = variants(node, acc.line)
    first = acc.n
    sites = for {{line, description, _}, i} <- Enum.with_index(variants), do: {first + i, line, description}
    acc = %{acc | n: first + length(variants), sites: Enum.reverse(sites, acc.sites)}
    {node, acc} = walk_children.(acc)

    case acc.target do
      t when is_integer(t) and t >= first and t < first + length(variants) ->
        {_, _, mutate} = Enum.at(variants, t - first)
        {mutate.(node), acc}

      _ ->
        {node, acc}
    end
  end

  # The mutations a node allows: `{line, description, fun}`, where `fun` mutates the node.
  defp variants({op, meta, [_, _]}, _line) when is_map_key(@negations, op) do
    boundary = if Map.has_key?(@boundaries, op), do: [rename(meta, op, @boundaries[op])], else: []
    [rename(meta, op, @negations[op]) | boundary]
  end

  defp variants({op, meta, [_, _]}, _line) when is_map_key(@swaps, op), do: [rename(meta, op, @swaps[op])]
  defp variants({:if, meta, [_, _]}, _line), do: [rename(meta, :if, :unless)]
  defp variants({:unless, meta, [_, _]}, _line), do: [rename(meta, :unless, :if)]
  defp variants({:in, meta, [_, _]}, _line), do: [{meta[:line], "in → not in", &{:not, meta, [&1]}}]
  defp variants({:not, meta, [_]}, _line), do: [{meta[:line], "not x → x", fn {_, _, [x]} -> x end}]
  defp variants({:!, meta, [_]}, _line), do: [{meta[:line], "!x → x", fn {_, _, [x]} -> x end}]
  defp variants({:__block__, _, exprs}, _line), do: clause_removals(exprs)

  defp variants({:case, _, [_, [do: clauses]]}, _line),
    do: arrow_removals("case", clauses, fn {f, m, [e, [do: cs]]}, i -> {f, m, [e, [do: List.delete_at(cs, i)]]} end)

  defp variants({:cond, _, [[do: clauses]]}, _line),
    do: arrow_removals("cond", clauses, fn {f, m, [[do: cs]]}, i -> {f, m, [[do: List.delete_at(cs, i)]]} end)

  defp variants({:fn, _, clauses}, _line),
    do: arrow_removals("fn", clauses, fn {f, m, cs}, i -> {f, m, List.delete_at(cs, i)} end)

  defp variants({:sigil_w, meta, [{:<<>>, _, [text]}, _]}, _line) when is_binary(text) do
    words = String.split(text)

    for {word, i} <- Enum.with_index(words), length(words) > 1 do
      {meta[:line], "word removed: #{word}",
       fn {f, m, [{:<<>>, m2, [_]}, mods]} -> {f, m, [{:<<>>, m2, [Enum.join(List.delete_at(words, i), " ")]}, mods]} end}
    end
  end

  defp variants(list, line) when is_list(list) and length(list) > 1 do
    if Enum.all?(list, &literal?/1) do
      for {element, i} <- Enum.with_index(list) do
        {line_of(element, line), "element removed: #{element |> Macro.to_string() |> String.slice(0, 60)}",
         &List.delete_at(&1, i)}
      end
    else
      []
    end
  end

  defp variants(_node, _line), do: []

  defp rename(meta, from, to), do: {meta[:line], "#{from} → #{to}", fn {_, m, args} -> {to, m, args} end}

  defp arrow_removals(kind, clauses, delete) when is_list(clauses) and length(clauses) > 1 do
    for {{:->, meta, _}, i} <- Enum.with_index(clauses),
        do: {meta[:line], "#{kind} clause removed", &delete.(&1, i)}
  end

  defp arrow_removals(_kind, _clauses, _delete), do: []

  # Clauses of a function with several, among the expressions of a module body.
  defp clause_removals(exprs) do
    keys = Enum.map(exprs, &function_key/1)
    counts = Enum.frequencies(keys)

    for {{key, expr}, i} <- Enum.with_index(Enum.zip(keys, exprs)), key != nil and counts[key] > 1 do
      {line_of(expr, nil), "clause removed: #{key}", fn {f, m, ex} -> {f, m, List.delete_at(ex, i)} end}
    end
  end

  defp function_key({kind, _, [head | _]}) when kind in [:def, :defp, :defmacro, :defmacrop] do
    case head do
      {:when, _, [{name, _, args} | _]} -> "#{name}/#{length(args || [])}"
      {name, _, args} -> "#{name}/#{length(args || [])}"
    end
  end

  defp function_key(_expr), do: nil

  defp literal?(x) when is_binary(x) or is_number(x) or is_atom(x), do: true
  defp literal?({sigil, _, [_, _]}) when is_atom(sigil), do: String.starts_with?(Atom.to_string(sigil), "sigil_")
  defp literal?(_x), do: false

  defp line_of({_, meta, _}, line) when is_list(meta), do: meta[:line] || line
  defp line_of(_node, line), do: line
end
