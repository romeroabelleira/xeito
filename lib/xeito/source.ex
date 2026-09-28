defmodule Xeito.Source do
  @moduledoc """
  Structure of source files for the tools, so a model can navigate code instead of grepping it
  (`Xeito.Tools`):

    * `outline/2`: a file's modules and definitions with their line ranges.
    * `symbol/3`: the source of one definition, by name (`init`, `init/1`, `Xeito.Tui.init/1`,
      or a module).
    * `syntax_error/2`: whether a file still parses, checked right after a `write` or `edit`.

  `Xeito.Source.RepoMap` builds a project map from the same parse.

  Elixir files (`.ex`, `.exs`) are parsed with Elixir's own parser (`Code.string_to_quoted/2`),
  so there are no dependencies; JSON files get a syntax check. Other languages are not supported
  yet: `outline/2` and `symbol/3` say so, and `syntax_error/2` returns `nil`.
  """

  @defs [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :defdelegate]

  @typedoc "One outline entry: a module, a definition (all clauses), or a test."
  @type entry :: %{
          kind: atom(),
          name: String.t(),
          module: String.t() | nil,
          first: pos_integer(),
          last: pos_integer(),
          clauses: pos_integer(),
          depth: non_neg_integer()
        }

  @doc "Whether outlines and symbols are available for `path`."
  @spec supported?(Path.t()) :: boolean()
  def supported?(path), do: Path.extname(path) in [".ex", ".exs"]

  @doc "The outline of a file as text, or `{:error, reason}`."
  @spec outline(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def outline(path, content) do
    with {:ok, entries} <- entries(path, content) do
      lines = length(String.split(content, "\n"))

      body = Enum.map_join(entries, "\n", &outline_line/1)

      {:ok,
       "#{path} · #{lines} lines · read one definition with symbol, e.g. \"name/arity\"\n" <> body}
    end
  end

  defp outline_line(e) do
    clauses = if e.clauses > 1, do: " (#{e.clauses} clauses)", else: ""
    String.duplicate("  ", e.depth) <> "#{e.kind} #{e.name}  #{e.first}-#{e.last}#{clauses}"
  end

  @doc """
  The source of the definitions matching `name`: `fun`, `fun/arity`, `Module.fun/arity`, or a
  module name (full or its last part). Each match is headed by its line range.
  """
  @spec symbol(Path.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def symbol(path, content, name) do
    with {:ok, entries} <- entries(path, content) do
      case Enum.filter(entries, &matches?(&1, name)) do
        [] ->
          {:error, "no definition #{inspect(name)} in #{path}; read it with outline: true"}

        found ->
          lines = String.split(content, "\n")

          {:ok,
           Enum.map_join(found, "\n\n", fn e ->
             "#{path} lines #{e.first}-#{e.last}:\n" <>
               (lines |> Enum.slice((e.first - 1)..(e.last - 1)//1) |> Enum.join("\n"))
           end)}
      end
    end
  end

  @doc "A description of the first syntax error in `content`, or `nil` if it parses (or is not checked)."
  @spec syntax_error(Path.t(), String.t()) :: String.t() | nil
  def syntax_error(path, content) do
    case Path.extname(path) do
      ext when ext in [".ex", ".exs"] ->
        case Code.string_to_quoted(content, file: path) do
          {:ok, _} ->
            nil

          {:error, {meta, message, token}} ->
            "line #{meta[:line]}: #{message_text(message)}#{token}"
        end

      ".json" ->
        case JSON.decode(content) do
          {:ok, _} -> nil
          {:error, reason} -> "invalid JSON: #{inspect(reason)}"
        end

      _ ->
        nil
    end
  end

  defp message_text({prefix, suffix}), do: prefix <> suffix
  defp message_text(message) when is_binary(message), do: message

  # --- parsing -------------------------------------------------------------------------------

  @doc false
  @spec entries(Path.t(), String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def entries(path, content) do
    cond do
      not supported?(path) ->
        {:error,
         "outline and symbol support Elixir files (.ex, .exs) so far; use grep for #{Path.extname(path)} files"}

      error = syntax_error(path, content) ->
        {:error, "#{path} does not parse (#{error}); read it without outline"}

      true ->
        {:ok, ast} = Code.string_to_quoted(content, columns: true, token_metadata: true)
        {:ok, ast |> collect(nil, 0) |> group()}
    end
  end

  defp collect({:defmodule, meta, [alias, [{:do, body} | _]]} = node, module, depth) do
    name = module_name(alias, module)

    [entry(:defmodule, name, nil, meta, node, depth) | collect(body, name, depth + 1)]
  end

  defp collect({kind, meta, [head | _]} = node, module, depth) when kind in @defs do
    case signature(head) do
      nil -> []
      sig -> [entry(kind, sig, module, meta, node, depth)]
    end
  end

  defp collect({:describe, meta, [name, [{:do, body} | _]]} = node, module, depth)
       when is_binary(name),
       do: [
         entry(:describe, inspect(name), module, meta, node, depth)
         | collect(body, module, depth + 1)
       ]

  defp collect({:test, meta, [name | _]} = node, module, depth) when is_binary(name),
    do: [entry(:test, inspect(name), module, meta, node, depth)]

  defp collect({:__block__, _meta, children}, module, depth),
    do: Enum.flat_map(children, &collect(&1, module, depth))

  defp collect({_call, _meta, args}, module, depth) when is_list(args) do
    # Definitions inside other blocks (quote, if, a DSL's do-blocks) still count.
    Enum.flat_map(args, fn
      [{:do, body} | _] -> collect(body, module, depth)
      _ -> []
    end)
  end

  defp collect(_node, _module, _depth), do: []

  defp entry(kind, name, module, meta, node, depth) do
    %{
      kind: kind,
      name: name,
      module: module,
      first: meta[:line],
      last: last_line(meta, node),
      clauses: 1,
      depth: depth
    }
  end

  # A do-block ends at its `end`; a one-liner at the end of its expression; anything else at
  # the deepest line inside it.
  defp last_line(meta, node) do
    cond do
      end_meta = meta[:end] -> end_meta[:line]
      eoe = meta[:end_of_expression] -> eoe[:line]
      true -> max_line(node)
    end
  end

  defp max_line(node) do
    {_, max} =
      Macro.prewalk(node, 0, fn
        {_, meta, _} = n, acc when is_list(meta) -> {n, max(acc, meta[:line] || 0)}
        n, acc -> {n, acc}
      end)

    max
  end

  defp module_name({:__aliases__, _, parts}, parent) do
    name = Enum.map_join(parts, ".", &to_string/1)
    if parent, do: "#{parent}.#{name}", else: name
  end

  defp module_name(other, _parent), do: Macro.to_string(other)

  defp signature({:when, _, [call | _]}), do: signature(call)

  defp signature({name, _, args}) when is_atom(name) and is_list(args),
    do: "#{name}/#{length(args)}"

  defp signature({name, _, context}) when is_atom(name) and is_atom(context), do: "#{name}/0"
  defp signature(_head), do: nil

  # Consecutive clauses of one definition become one entry.
  defp group(entries) do
    entries
    |> Enum.chunk_while(
      nil,
      fn
        e, nil ->
          {:cont, e}

        e, %{kind: k, name: n, module: m} = acc
        when e.kind == k and e.name == n and e.module == m and k != :defmodule ->
          {:cont, %{acc | last: max(acc.last, e.last), clauses: acc.clauses + 1}}

        e, acc ->
          {:cont, acc, e}
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
  end

  defp matches?(%{kind: :defmodule, name: module}, name),
    do: module == name or String.ends_with?(module, "." <> name)

  defp matches?(%{kind: kind, name: sig, module: module}, name) when kind in @defs do
    {mod, fun} = split_name(name)
    [fname, _arity] = String.split(sig, "/")

    (fun == sig or fun == fname) and
      (mod == nil or (module != nil and (module == mod or String.ends_with?(module, "." <> mod))))
  end

  defp matches?(%{name: test}, name), do: test == inspect(name) or test == name

  # "Mod.Sub.fun/2" → {"Mod.Sub", "fun/2"}; "fun" → {nil, "fun"}.
  defp split_name(name) do
    case Regex.run(~r/^(.+)\.([^.\/]+(\/\d+)?)$/, name) do
      [_, mod, fun | _] -> {mod, fun}
      nil -> {nil, name}
    end
  end
end
