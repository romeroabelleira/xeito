defmodule Xeito.Skills.IndexTest do
  @moduledoc "P4f step 2: skills ranked by BM25 over normalised words."
  use ExUnit.Case, async: true

  alias Xeito.Skills.Index

  defp skill(name, description),
    do: %{name: name, description: description, dir: "/home/u/.agents/skills/#{name}", model_invocation: true}

  defp library,
    do: [
      skill("youtube-transcript", "Fetch transcripts from YouTube videos for summarization and analysis."),
      skill("code-review", "Review the changes since a fixed point along two axes: standards and spec."),
      skill("diagnosing-bugs", "Diagnosis loop for hard bugs and performance regressions."),
      skill("tdd", "Test-driven development: red, green, refactor."),
      skill("brave-search", "Web search and content extraction via Brave Search API.")
    ]

  defp names(skills), do: Enum.map(skills, & &1.name)

  describe "normalize/1: one spelling for the index and the query" do
    test "lower case, and British endings in their American form" do
      assert Index.normalize("Summarise the Colour") == "summarize the color"
      assert Index.normalize("organisation, organised, summarising") == "organization, organized, summarizing"
    end

    test "American spellings are left as they are" do
      assert Index.normalize("summarize the color of the organization") == "summarize the color of the organization"
    end
  end

  describe "search/3: the shortlist of a turn" do
    test "finds a skill by another form or spelling of its words" do
      assert ["youtube-transcript"] = library() |> Index.search("summarise this youtube talk") |> names()
      assert ["diagnosing-bugs"] = library() |> Index.search("diagnose the performance regression") |> names()
    end

    test "a word of a skill's name weighs more than a word of another's description" do
      skills = [skill("notes", "Search notes and saved web clippings."), skill("web-search", "Find pages.")]
      assert ["web-search", "notes"] = skills |> Index.search("web search") |> names()
    end

    test "needs two of the request's words, or one of the skill's name" do
      assert Index.search(library(), "check the standards") == []
      assert ["code-review"] = library() |> Index.search("check the standards and spec") |> names()
      assert ["code-review"] = library() |> Index.search("review it") |> names()
    end

    test "a word of two letters counts" do
      pr = skill("pr", "Use when writing a PR body.")
      assert ["pr"] = [pr | library()] |> Index.search("write the pr") |> names()
    end

    test "filler words find nothing" do
      assert Index.search(library(), "what is the use of this when the user wants it") == []
      assert Index.search(library(), "") == []
    end

    test "at most k, the best first" do
      many = for n <- 1..5, do: skill("search-#{n}", "Search the web for pages.")
      assert length(Index.search(many, "search the web")) == 3
      assert length(Index.search(many, "search the web", k: 5)) == 5
    end

    test "diacritics are ignored" do
      assert ["cover-letter"] = [skill("cover-letter", "Write a résumé.")] |> Index.search("write my resume") |> names()
    end

    test "the query syntax of the index is not the request's" do
      for request <- [~s(fix "it" NEAR\( review* -bar AND: ^tdd), "OR OR review", "review:"] do
        assert is_list(Index.search(library(), request))
      end
    end

    test "no skills, no shortlist" do
      assert Index.search([], "review the changes") == []
    end
  end

  describe "search/3 with any: true, for finding skills by hand" do
    test "one word is enough, the best first" do
      assert ["code-review"] = library() |> Index.search("standards", any: true) |> names()
      assert ["brave-search", "youtube-transcript"] = library() |> Index.search("search videos", any: true) |> names()
    end

    test "a fragment of a word finds the skills that contain it" do
      assert ["youtube-transcript"] = library() |> Index.search("youtub", any: true) |> names()
      assert ["youtube-transcript"] = library() |> Index.search("transcri", any: true) |> names()
      assert ["youtube-transcript"] = library() |> Index.search("ube", any: true) |> names()
      assert Index.search(library(), "qq", any: true) == []
    end
  end
end
