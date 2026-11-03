defmodule Xeito.Source.PlanCheck do
  @moduledoc """
  Checks the implementation plan against the repository, for `mix xeito.plan.check`.

  Four checks, each a finding per plan line, and nothing is changed:

    * modules: every `Xeito.Some.Module`, `Mix.Tasks.Xeito.X` and `mix xeito.x` the plan names
      has a `defmodule` under `lib/` or `test/`, unless the line says it is planned, removed,
      renamed, not adopted, or was
    * links: every `](#anchor)` slugs a heading of the plan (GitHub's rules), and every relative
      link reaches a file, its fragment a heading of that file
    * stale: a `(checked YYYY-MM-DD` note older than 14 days (the last one on a line counts); a "next", "pending", "planned" or
      "waits for" item whose nearest date (on its line, else the last one above) is older than 60
      days
    * milestones: a milestone-table row that says done needs a section whose status line says
      done or whose last step is marked done; a section whose steps are all marked done, or whose
      status line says done, needs a row that says done
  """

  @type check :: :modules | :links | :stale | :milestones
  @type finding :: {check(), line :: pos_integer(), String.t()}

  @checks [modules: "Modules", links: "Links", stale: "Stale", milestones: "Milestones"]
  @checked_days 14
  @item_days 60

  @module ~r/\bMix\.Tasks\.Xeito(?:\.[A-Z]\w*)*|\bXeito(?:\.[A-Z]\w*)+|\bmix xeito(?:\.[a-z0-9_]+)*/
  @exempt ~r/\b(planned|removed|renamed|not adopted|was)\b/i
  @definition ~r/^\s*defmodule\s+([A-Z][\w.]*)/m
  @link ~r/\]\(([^)\s]+)\)/
  @heading ~r/^\#{1,6}\s+(.+?)\s*$/
  @date ~r/\d{4}-\d{2}-\d{2}/
  @checked ~r/\(checked (\d{4}-\d{2}-\d{2})/
  @item ~r/\b(next|pending|planned|waits for)\b/i
  @phase ~r/^## (P(?:\d\w*|X))\b/
  @row ~r/^\|\s*(P(?:\d\w*|X))\b[^|]*\|[^|]*\|[^|]*\|([^|]*)\|/
  @step ~r/^\d+\. /
  @step_done ~r/\*\*Done\b|\(done \d{4}|\(added and done \d{4}|✅/
  @status_done ~r/^\*\*Status:?\*\*\W*done\b/

  @doc """
  The findings for the plan at `plan:`, checked against the repository at `root:` (the current
  directory by default) as of `today:` (the current date by default), in plan order.
  """
  @spec run(keyword()) :: [finding()]
  def run(opts) do
    plan = Keyword.fetch!(opts, :plan)
    root = Keyword.get(opts, :root, ".")
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)
    lines = plan |> File.read!() |> numbered()

    modules(lines, defined(root)) ++ links(lines, Path.dirname(plan)) ++ stale(lines, today) ++ milestones(lines)
  end

  @doc "The findings by check, each with its plan line, then their count."
  @spec format([finding()]) :: String.t()
  def format(findings) do
    groups =
      Enum.map_join(@checks, "\n", fn {check, title} ->
        lines = for {^check, line, text} <- Enum.sort_by(findings, &elem(&1, 1)), do: "\n  line #{line}: #{text}"
        "#{title} (#{length(lines)})#{lines}"
      end)

    groups <> "\n\n" <> count(length(findings))
  end

  defp count(0), do: "no findings"
  defp count(1), do: "1 finding"
  defp count(n), do: "#{n} findings"

  @doc "A heading's anchor, as GitHub slugs it: lowercase, punctuation dropped, spaces to hyphens."
  @spec slug(String.t()) :: String.t()
  def slug(heading) do
    heading |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "") |> String.replace(" ", "-")
  end

  defp numbered(text), do: text |> String.split("\n") |> Enum.with_index(fn line, i -> {i + 1, line} end)

  # --- modules ---

  defp modules(lines, defined) do
    for {n, text} <- lines,
        not Regex.match?(@exempt, text),
        name <- @module |> Regex.scan(text) |> List.flatten() |> Enum.uniq(),
        module = module_name(name),
        module not in defined,
        do: {:modules, n, "#{label(name, module)} is not defined (no defmodule in lib/ or test/)"}
  end

  defp module_name("mix " <> task),
    do: "Mix.Tasks." <> (task |> String.split(".") |> Enum.map_join(".", &Macro.camelize/1))

  defp module_name(name), do: name

  defp label(name, name), do: name
  defp label(name, module), do: "#{name} (#{module})"

  defp defined(root) do
    root
    |> Path.join("{lib,test}/**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.flat_map(&Regex.scan(@definition, File.read!(&1), capture: :all_but_first))
    |> List.flatten()
    |> MapSet.new()
  end

  # --- links ---

  defp links(lines, dir) do
    slugs = slugs(lines)

    for {n, text} <- lines,
        [target] <- Regex.scan(@link, text, capture: :all_but_first),
        problem = link_problem(target, slugs, dir),
        do: {:links, n, "#{target} #{problem}"}
  end

  defp link_problem("#" <> anchor, slugs, _dir), do: if(anchor not in slugs, do: "points to no heading of the plan")

  defp link_problem(target, _slugs, dir) do
    if !String.match?(target, ~r/^[a-z][a-z0-9+.-]*:/), do: file_problem(String.split(target, "#", parts: 2), dir)
  end

  defp file_problem([path | fragment], dir) do
    full = Path.expand(path, dir)

    cond do
      not File.regular?(full) -> "points to no file"
      fragment == [] or not String.ends_with?(path, ".md") -> nil
      hd(fragment) in (full |> File.read!() |> numbered() |> slugs()) -> nil
      true -> "points to no heading of #{path}"
    end
  end

  # The anchors of the headings, in order; a repeated heading gets -1, -2, … as on GitHub.
  defp slugs(lines) do
    lines
    |> headings()
    |> Enum.map_reduce(%{}, fn heading, seen ->
      slug = slug(heading)
      {if(seen[slug], do: "#{slug}-#{seen[slug]}", else: slug), Map.update(seen, slug, 1, &(&1 + 1))}
    end)
    |> elem(0)
  end

  # Heading texts, outside fenced code blocks.
  defp headings(lines) do
    lines
    |> Enum.reduce({false, []}, fn
      {_n, "```" <> _}, {fenced, acc} -> {not fenced, acc}
      {_n, text}, {false, acc} -> {false, (Regex.run(@heading, text, capture: :all_but_first) || []) ++ acc}
      _fenced_line, state -> state
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # --- stale ---

  defp stale(lines, today) do
    dates =
      for {n, text} <- lines, {start, len} <- positions(@date, text), do: {n, start, binary_part(text, start, len)}

    checked =
      for {n, text} <- lines,
          date <- @checked |> Regex.scan(text, capture: :all_but_first) |> List.flatten() |> Enum.take(-1),
          days = age(date, today),
          days > @checked_days,
          do: {:stale, n, "(checked #{date} is #{days} days old (over #{@checked_days})"}

    items =
      for {n, text} <- lines,
          {start, len} <- positions(@item, text),
          {date, days} <- [nearest(dates, n, start, today)],
          days > @item_days,
          do:
            {:stale, n,
             "\"#{binary_part(text, start, len)}\" item, last dated #{date}, #{days} days ago (over #{@item_days})"}

    Enum.sort_by(checked ++ items, fn {_check, n, _text} -> n end)
  end

  defp positions(regex, text), do: regex |> Regex.scan(text, return: :index) |> Enum.map(&hd/1)

  # The date nearest to column `start` of line `n`, else the last one above; nil without any.
  defp nearest(dates, n, start, today) do
    on_line = for {^n, col, date} <- dates, do: {abs(col - start), date}
    above = for {line, col, date} <- dates, line < n, do: {{line, col}, date}

    case {on_line, above} do
      {[_ | _], _} -> on_line |> Enum.min() |> elem(1) |> aged(today)
      {[], [_ | _]} -> above |> Enum.max() |> elem(1) |> aged(today)
      {[], []} -> nil
    end
  end

  defp aged(date, today), do: {date, age(date, today)}

  defp age(date, today) do
    case Date.from_iso8601(date) do
      {:ok, date} -> Date.diff(today, date)
      {:error, _reason} -> 0
    end
  end

  # --- milestones ---

  defp milestones(lines) do
    sections = sections(lines)
    milestones = Enum.find(sections, [], fn [{_n, heading} | _rest] -> heading =~ ~r/^## Milestones\b/ end)

    phases =
      for [{n, heading} | _rest] = section <- sections, [id] <- [phase(heading)], into: %{}, do: {id, {n, section}}

    for {n, text} <- milestones,
        [id, status] <- Regex.scan(@row, text, capture: :all_but_first),
        {start, section} <- [phases[id]],
        problem <- [disagreement(String.trim(status) =~ ~r/^done\b/, section, start)],
        problem != nil,
        do: {:milestones, n, "#{id}: #{problem}"}
  end

  defp phase(heading), do: Regex.run(@phase, heading, capture: :all_but_first)

  # The lines of each `## ` section, heading first.
  defp sections(lines) do
    lines |> Enum.drop_while(fn {_n, text} -> not (text =~ ~r/^## /) end) |> chunks(fn {_n, text} -> text =~ ~r/^## / end)
  end

  # `enum` cut before every element `starts?` accepts.
  defp chunks(enum, starts?) do
    Enum.chunk_while(
      enum,
      [],
      fn element, acc ->
        if starts?.(element) and acc != [], do: {:cont, Enum.reverse(acc), [element]}, else: {:cont, [element | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp disagreement(row_done?, section, start) do
    status_done? = Enum.any?(section, fn {_n, text} -> text =~ @status_done end)
    verdict(row_done?, status_done?, section |> steps() |> steps_done(), start)
  end

  # :all when every step is marked done, :last when only the last is, :none otherwise or without steps.
  defp steps_done([]), do: :none

  defp steps_done(steps) do
    done = Enum.map(steps, &(&1 =~ @step_done))

    cond do
      Enum.all?(done) -> :all
      List.last(done) -> :last
      true -> :none
    end
  end

  defp verdict(true, false, :none, start),
    do:
      "the table says done, but the section (line #{start}) has no done status line and its last step is not marked done"

  defp verdict(false, _status_done?, :all, start),
    do: "every step of the section (line #{start}) is done, but the table row does not say so"

  defp verdict(false, true, _steps_done, start), do: "the section (line #{start}) says done, but the table row does not"
  defp verdict(_row_done?, _status_done?, _steps_done, _start), do: nil

  # Each numbered step with its indented continuation lines, as one text.
  defp steps(section) do
    section
    |> Enum.map(&elem(&1, 1))
    |> chunks(&(not (&1 =~ ~r/^\s+\S/)))
    |> Enum.filter(&(hd(&1) =~ @step))
    |> Enum.map(&Enum.join(&1, "\n"))
  end
end
