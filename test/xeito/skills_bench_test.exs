defmodule Xeito.Skills.BenchTest do
  @moduledoc "P4f step 1: how well a request finds the skill it needs."
  use ExUnit.Case, async: true

  alias Xeito.Skills
  alias Xeito.Skills.Bench

  defp skill(name, description, opts \\ []),
    do: %{
      name: name,
      description: description,
      dir: "/home/u/.agents/skills/#{name}",
      model_invocation: Keyword.get(opts, :model_invocation, true)
    }

  defp library,
    do: [
      skill("youtube-transcript", "Fetch transcripts from YouTube videos for summarization and analysis."),
      skill("code-review", "Review the changes since a fixed point along two axes: standards and spec."),
      skill("brave-search", "Web search and content extraction via Brave Search API.")
    ]

  defp tmp(name, content) do
    path = Path.join(System.tmp_dir!(), "xeito-bench-#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "Skills.shortlist/2: the user's skills a turn may choose from" do
    test "ranks the skills the model may invoke, and leaves out the others" do
      manual = skill("transcribe", "Fetch transcripts of YouTube videos.", model_invocation: false)

      assert ["youtube-transcript"] =
               [manual | library()] |> Skills.shortlist("get the transcript of this youtube video") |> Enum.map(& &1.name)
    end
  end

  describe "Skills.from_dirs/1" do
    test "loads every SKILL.md under the directories, sorted, the first of a name winning" do
      root = Path.join(System.tmp_dir!(), "xeito-bench-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)

      for {dir, name, desc} <- [
            {"a/b/beta", "beta", "Second."},
            {"alpha", "alpha", "First."},
            {"z/beta", "beta", "Shadowed."}
          ] do
        File.mkdir_p!(Path.join(root, dir))
        File.write!(Path.join([root, dir, "SKILL.md"]), "---\nname: #{name}\ndescription: #{desc}\n---\nBody\n")
      end

      assert [%{name: "beta", description: "Second."}, %{name: "alpha"}] = Skills.from_dirs([root])
      assert Skills.from_dirs([Path.join(root, "missing")]) == []
    end
  end

  describe "read_set/1: the benchmark's cases" do
    test "one JSON object per line pairs a request with a skill, or with none; blank lines are skipped" do
      path =
        tmp("set.jsonl", """
        {"request": "summarise this youtube talk", "skill": "youtube-transcript"}

        {"request": "rename this module", "skill": "none"}
        """)

      assert Bench.read_set(path) == [
               %{request: "summarise this youtube talk", skill: "youtube-transcript"},
               %{request: "rename this module", skill: :none}
             ]
    end

    test "a line that is not a case names its line number" do
      path = tmp("bad.jsonl", ~s({"request": "a", "skill": "b"}\n{"request": "no skill"}\n))
      assert_raise ArgumentError, ~r/line 2/, fn -> Bench.read_set(path) end

      path = tmp("broken.jsonl", "not json\n")
      assert_raise ArgumentError, ~r/line 1/, fn -> Bench.read_set(path) end
    end
  end

  describe "run/3: recall, empty shortlists for requests that need none, misses and latency" do
    # A stand-in shortlist: the skills named in the request, in the order the request names them.
    defp named(skills, request) do
      request
      |> String.split()
      |> Enum.flat_map(fn word -> Enum.filter(skills, &(&1.name == word)) end)
    end

    test "counts the cases whose skill is first, and those whose skill is in the shortlist" do
      cases = [
        %{request: "youtube-transcript please", skill: "youtube-transcript"},
        %{request: "brave-search code-review", skill: "code-review"},
        %{request: "nothing named", skill: "brave-search"},
        %{request: "rename this", skill: :none},
        %{request: "code-review it", skill: :none},
        %{request: "whatever", skill: "not-installed"}
      ]

      report = Bench.run(library(), cases, &named/2)

      assert %{skills: 3, cases: 6, needing: 3, top1: 1, top3: 2, none: 2, none_empty: 1} = report
      assert report.unknown == ["not-installed"]

      assert report.misses == [
               %{request: "brave-search code-review", skill: "code-review", got: ["brave-search", "code-review"]},
               %{request: "nothing named", skill: "brave-search", got: []},
               %{request: "code-review it", skill: :none, got: ["code-review"]}
             ]

      assert %{mean: mean, p95: p95} = report.latency_us
      assert mean >= 0 and p95 >= 0
    end

    test "a skill ranked below the third counts for neither" do
      many = for n <- 1..4, do: skill("s#{n}", "Skill #{n}.")
      report = Bench.run(many, [%{request: "s1 s2 s3 s4", skill: "s4"}], &named/2)
      assert %{top1: 0, top3: 0} = report
    end

    test "uses the turn's shortlist by default" do
      report = Bench.run(library(), [%{request: "get the transcript of this youtube video", skill: "youtube-transcript"}])
      assert %{top1: 1, top3: 1, misses: []} = report
    end

    test "an empty set measures nothing" do
      assert %{cases: 0, needing: 0, none: 0, latency_us: %{mean: 0, p95: 0}} = Bench.run(library(), [])
    end
  end

  describe "format/1" do
    test "reports counts with shares, then each miss and the unknown skills" do
      report = %{
        skills: 3,
        cases: 4,
        needing: 2,
        top1: 1,
        top3: 1,
        none: 2,
        none_empty: 1,
        unknown: ["not-installed"],
        misses: [
          %{request: "summarise this youtube talk", skill: "youtube-transcript", got: []},
          %{request: "review it", skill: :none, got: ["code-review", "brave-search"]}
        ],
        latency_us: %{mean: 12, p95: 40}
      }

      assert Bench.format(report) == """
             3 skills, 4 cases: 2 need a skill, 2 need none
             top 1: 1/2 (50%) · top 3: 1/2 (50%)
             none: 1/2 with an empty shortlist (50%)
             latency: mean 12 µs · p95 40 µs
             misses:
               "summarise this youtube talk" → youtube-transcript, got nothing
               "review it" → none, got code-review, brave-search
             not in the library: not-installed
             """
    end

    test "leaves out shares of nothing, and the sections with nothing to show" do
      report = %{
        skills: 0,
        cases: 0,
        needing: 0,
        top1: 0,
        top3: 0,
        none: 0,
        none_empty: 0,
        unknown: [],
        misses: [],
        latency_us: %{mean: 0, p95: 0}
      }

      assert Bench.format(report) == """
             0 skills, 0 cases: 0 need a skill, 0 need none
             top 1: 0/0 · top 3: 0/0
             none: 0/0 with an empty shortlist
             latency: mean 0 µs · p95 0 µs
             """
    end
  end

  describe "the shipped sample" do
    test "every skill the sample set names is in the sample library, and both cover both kinds of case" do
      library = Skills.from_dirs([Bench.sample_skills()])
      cases = Bench.read_set(Bench.sample_set())
      names = MapSet.new(library, & &1.name)

      assert length(library) >= 8
      assert Enum.all?(cases, &(&1.skill == :none or MapSet.member?(names, &1.skill)))
      assert Enum.count(cases, &(&1.skill == :none)) >= 5
      assert Enum.count(cases, &(&1.skill != :none)) >= 20
    end
  end
end
