defmodule Xeito.Source.ModuleMap do
  @moduledoc """
  Renders the codebase's interface as text from the compiled modules, for `mix xeito.map`.

  Each module gets a line with its file and the first sentence of its moduledoc (cut at 160
  characters); with `functions: true`, its documented public functions follow, by spec where given.
  """

  @type entry :: %{module: module(), file: String.t(), summary: String.t(), functions: [String.t()]}

  @max_summary 160

  @doc "Xeito's modules whose name starts with `prefix` (all of them for `nil`), sorted; no mix tasks."
  @spec modules(String.t() | nil) :: [module()]
  def modules(prefix) do
    :xeito
    |> Application.spec(:modules)
    |> Enum.filter(&(not String.starts_with?(inspect(&1), "Mix.") and under?(inspect(&1), prefix)))
    |> Enum.sort()
  end

  defp under?(_name, nil), do: true
  defp under?(name, prefix), do: name == prefix or String.starts_with?(name, prefix <> ".")

  @doc "One module's file, summary and public functions (specs where it has them)."
  @spec entry(module()) :: entry()
  def entry(module) do
    {moduledoc, docs} = docs(module)

    %{
      module: module,
      file: module.module_info(:compile)[:source] |> to_string() |> Path.relative_to_cwd(),
      summary: summary(moduledoc),
      functions: functions(docs, specs(module))
    }
  end

  defp docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, docs} -> {doc, docs}
      {:docs_v1, _, _, _, _hidden_or_none, _, docs} -> {nil, docs}
      _ -> {nil, []}
    end
  end

  @doc false
  # Public and documented (not `@doc false`), in source order; by their specs where given.
  def functions(docs, specs) do
    for {{kind, name, arity}, _anno, _sig, doc, _meta} <- docs,
        kind in [:function, :macro],
        doc != :hidden,
        rendered <- Map.get(specs, {name, arity}, ["#{name}/#{arity}"]),
        do: rendered
  end

  defp specs(module) do
    case Code.Typespec.fetch_specs(module) do
      {:ok, specs} ->
        Map.new(specs, fn {{name, arity}, list} ->
          {{name, arity}, Enum.map(list, &(name |> Code.Typespec.spec_to_quoted(&1) |> Macro.to_string() |> one_line()))}
        end)

      :error ->
        %{}
    end
  end

  @doc false
  # A spec the formatter broke over several lines, on one.
  def one_line(text),
    do: text |> String.replace(~r/\s*\n\s*/, " ") |> String.replace("( ", "(") |> String.replace(" )", ")")

  @doc "The first sentence of a moduledoc, on one line."
  @spec summary(String.t() | nil) :: String.t()
  def summary(nil), do: ""

  def summary(doc) do
    paragraph = doc |> String.split(~r/\n\s*\n/, parts: 2) |> hd() |> String.replace(~r/\s*\n\s*/, " ")

    sentence =
      case Regex.run(~r/^.*?\.(?=\s|$)/, paragraph) do
        [first] -> first
        nil -> paragraph
      end

    sentence |> String.trim() |> String.slice(0, @max_summary)
  end

  @doc "The map: a line per module, with its functions indented under it when `functions: true`."
  @spec format([entry()], keyword()) :: String.t()
  def format(entries, opts) do
    Enum.map_join(entries, "\n", fn e ->
      head = "#{inspect(e.module)}  #{e.file}  #{e.summary}"

      if opts[:functions] && e.functions != [],
        do: head <> "\n" <> Enum.map_join(e.functions, "\n", &("  " <> &1)),
        else: head
    end)
  end
end
