defmodule Xeito.Skills.Bench do
  @moduledoc """
  Measures how well requests find the skills they need: the shortlist a chat turn gives its skill
  decision (`Xeito.Skills.shortlist/2`), against a set of requests labelled with the skill each
  one needs, or with `none` (P4f step 1, `mix xeito.skills.bench`).

  A set is JSON Lines, one case per line: `{"request": "…", "skill": "name"}` or
  `{"skill": "none"}`. The report counts:

    * **top 1** and **top 3**: of the requests that need a skill, those whose skill is first in
      the shortlist, and those whose skill is in it at all (it holds at most three);
    * **none**: of the requests that need no skill, those with an empty shortlist, so the turn
      decides without a model call;
    * the **misses**, with what the shortlist held instead, and the time the shortlist took.

  Skills the set names but the library lacks are reported and left out of the counts. A sample
  library and set ship in `priv/skills/bench`; an operator measures their own set against their
  own library.
  """

  alias Xeito.Skills

  @type bench_case :: %{request: String.t(), skill: String.t() | :none}
  @type miss :: %{request: String.t(), skill: String.t() | :none, got: [String.t()]}
  @type report :: %{
          skills: non_neg_integer(),
          cases: non_neg_integer(),
          needing: non_neg_integer(),
          top1: non_neg_integer(),
          top3: non_neg_integer(),
          none: non_neg_integer(),
          none_empty: non_neg_integer(),
          unknown: [String.t()],
          misses: [miss()],
          latency_us: %{mean: non_neg_integer(), p95: non_neg_integer()}
        }

  @doc "The sample skill library."
  @spec sample_skills() :: Path.t()
  def sample_skills, do: Application.app_dir(:xeito, ["priv", "skills", "bench", "skills"])

  @doc "The sample set, labelled against the sample library."
  @spec sample_set() :: Path.t()
  def sample_set, do: Application.app_dir(:xeito, ["priv", "skills", "bench", "set.jsonl"])

  @doc "Reads a set. Raises `ArgumentError`, naming the line, on a line that is not a case."
  @spec read_set(Path.t()) :: [bench_case()]
  def read_set(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> String.trim(line) == "" end)
    |> Enum.map(&read_case/1)
  end

  defp read_case({line, n}) do
    case JSON.decode(line) do
      {:ok, %{"request" => request, "skill" => skill}} when is_binary(request) and is_binary(skill) ->
        %{request: request, skill: label(skill)}

      _ ->
        raise ArgumentError, "line #{n} is not a case: #{line}"
    end
  end

  defp label("none"), do: :none
  defp label(name), do: name

  @doc "Runs the cases against a library through `shortlist` (by default the chat turn's)."
  @spec run([Skills.t()], [bench_case()], ([Skills.t()], String.t() -> [Skills.t()])) :: report()
  def run(skills, cases, shortlist \\ &Skills.shortlist/2) do
    names = MapSet.new(skills, & &1.name)
    {known, unknown} = Enum.split_with(cases, &(&1.skill == :none or MapSet.member?(names, &1.skill)))
    results = Enum.map(known, &measure(&1, skills, shortlist))
    {needing, none} = Enum.split_with(results, fn {bench_case, _got, _us} -> bench_case.skill != :none end)

    %{
      skills: length(skills),
      cases: length(cases),
      needing: length(needing),
      top1: Enum.count(needing, &first?/1),
      top3: Enum.count(needing, &listed?/1),
      none: length(none),
      none_empty: Enum.count(none, fn {_case, got, _us} -> got == [] end),
      unknown: unknown |> Enum.map(& &1.skill) |> Enum.uniq(),
      misses: for({bench_case, got, _us} = result <- results, miss?(result), do: Map.put(bench_case, :got, got)),
      latency_us: latency(Enum.map(results, fn {_case, _got, us} -> us end))
    }
  end

  defp measure(bench_case, skills, shortlist) do
    {us, got} = :timer.tc(fn -> shortlist.(skills, bench_case.request) end)
    {bench_case, Enum.map(got, & &1.name), us}
  end

  defp first?({%{skill: skill}, got, _us}), do: List.first(got) == skill
  defp listed?({%{skill: skill}, got, _us}), do: skill in Enum.take(got, 3)

  defp miss?({%{skill: :none}, got, _us}), do: got != []
  defp miss?(result), do: not first?(result)

  defp latency([]), do: %{mean: 0, p95: 0}

  defp latency(times) do
    sorted = Enum.sort(times)
    %{mean: div(Enum.sum(sorted), length(sorted)), p95: Enum.at(sorted, ceil(0.95 * length(sorted)) - 1)}
  end

  @doc "The report as text, one line per count, then the misses and the unknown skills."
  @spec format(report()) :: String.t()
  def format(report) do
    [
      "#{report.skills} skills, #{report.cases} cases: #{report.needing} need a skill, #{report.none} need none",
      "top 1: #{share(report.top1, report.needing)} · top 3: #{share(report.top3, report.needing)}",
      "none: #{report.none_empty}/#{report.none} with an empty shortlist#{percent(report.none_empty, report.none)}",
      "latency: mean #{report.latency_us.mean} µs · p95 #{report.latency_us.p95} µs"
    ]
    |> Kernel.++(miss_lines(report.misses))
    |> Kernel.++(unknown_lines(report.unknown))
    |> Enum.map_join(&(&1 <> "\n"))
  end

  defp share(n, of), do: "#{n}/#{of}#{percent(n, of)}"

  defp percent(_n, 0), do: ""
  defp percent(n, of), do: " (#{round(100 * n / of)}%)"

  defp miss_lines([]), do: []

  defp miss_lines(misses),
    do: ["misses:" | Enum.map(misses, &~s(  "#{&1.request}" → #{name(&1.skill)}, got #{got(&1.got)}))]

  defp name(:none), do: "none"
  defp name(skill), do: skill

  defp got([]), do: "nothing"
  defp got(names), do: Enum.join(names, ", ")

  defp unknown_lines([]), do: []
  defp unknown_lines(names), do: ["not in the library: " <> Enum.join(names, ", ")]
end
