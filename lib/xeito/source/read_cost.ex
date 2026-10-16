defmodule Xeito.Source.ReadCost do
  @moduledoc """
  Estimates what reading files costs an agent in tokens, and how much of it is doc text and comments.

  Tokens are counted as 4 characters each. `measure/2` takes tasks, each with the files read to
  do it, plus files read for every task (`always`), and returns the cost per task and in total.
  """

  @type cost :: %{tokens: non_neg_integer(), prose: non_neg_integer()}
  @type set :: %{always: [Path.t()], tasks: [%{name: String.t(), files: [Path.t()]}]}
  @type report :: %{
          always: non_neg_integer(),
          tasks: [%{name: String.t(), tokens: non_neg_integer(), prose: non_neg_integer(), missing: [Path.t()]}],
          total: non_neg_integer(),
          prose: non_neg_integer()
        }

  @doc "The cost of one file's text."
  @spec file(String.t()) :: cost()
  def file(text) do
    prose =
      text
      |> String.split("\n")
      |> Enum.reduce({0, :code}, &line/2)
      |> elem(0)

    %{tokens: tokens(String.length(text)), prose: tokens(prose)}
  end

  # Accumulator: characters of prose so far, and whether inside a doc (`:heredoc`, `:string`) or `:code`.
  defp line(line, {n, :heredoc}), do: {n + String.length(line) + 1, if(closes_heredoc?(line), do: :code, else: :heredoc)}

  defp line(line, {n, :string}),
    do: {n + String.length(line) + 1, if(String.contains?(line, ~s(")), do: :code, else: :string)}

  defp line(line, {n, :code}) do
    case doc_start(String.trim_leading(line)) do
      :none -> {n, :code}
      kind -> {n + String.length(line) + 1, kind}
    end
  end

  # A comment line is prose; the next line is code again.
  defp doc_start("#" <> _), do: :code
  defp doc_start("@moduledoc " <> rest), do: doc_or_none(rest)
  defp doc_start("@doc " <> rest), do: doc_or_none(rest)
  defp doc_start(_line), do: :none

  defp doc_or_none("false" <> _), do: :none
  defp doc_or_none(rest), do: doc_kind(rest)

  defp doc_kind(rest) do
    cond do
      String.starts_with?(rest, [~s("""), "'''", ~s(~S""")]) ->
        :heredoc

      # A one-line string closes on the same line; one that does not runs on.
      String.starts_with?(rest, ~s(")) ->
        if String.contains?(String.slice(rest, 1..-1//1), ~s(")), do: :code, else: :string

      true ->
        :code
    end
  end

  defp closes_heredoc?(line), do: String.trim(line) in [~s("""), ~s(''')]

  @doc "The cost of every task in `set`, reading files with `read` (`File.read/1` by default)."
  @spec measure(set(), (Path.t() -> {:ok, String.t()} | {:error, term()} | :error)) :: report()
  def measure(set, read \\ &File.read/1) do
    {always, _} = files(set.always, read)

    tasks =
      for task <- set.tasks do
        {cost, missing} = files(task.files, read)
        %{name: task.name, tokens: always.tokens + cost.tokens, prose: cost.prose, missing: missing}
      end

    %{
      always: always.tokens,
      tasks: tasks,
      total: tasks |> Enum.map(& &1.tokens) |> Enum.sum(),
      prose: tasks |> Enum.map(& &1.prose) |> Enum.sum()
    }
  end

  defp files(paths, read) do
    Enum.reduce(paths, {%{tokens: 0, prose: 0}, []}, fn path, {sum, missing} ->
      case read.(path) do
        {:ok, text} -> {add(sum, file(text)), missing}
        _ -> {sum, missing ++ [path]}
      end
    end)
  end

  defp add(a, b), do: %{tokens: a.tokens + b.tokens, prose: a.prose + b.prose}

  defp tokens(chars), do: ceil(chars / 4)

  @doc "The report as a table."
  @spec format(report()) :: String.t()
  def format(report) do
    rows =
      Enum.map_join(report.tasks, "\n", fn t ->
        row = "#{String.pad_trailing(t.name, 44)} #{pad(t.tokens)} #{pad(t.prose)}"
        if t.missing == [], do: row, else: row <> "   missing: " <> Enum.join(t.missing, ", ")
      end)

    """
    always read: #{report.always} tokens (AGENTS.md and what it points to)

    #{String.pad_trailing("task", 44)} #{pad("tokens")} #{pad("prose")}
    #{rows}
    #{String.pad_trailing("total", 44)} #{pad(report.total)} #{pad(report.prose)}
    """
  end

  defp pad(value), do: value |> to_string() |> String.pad_leading(7)
end
