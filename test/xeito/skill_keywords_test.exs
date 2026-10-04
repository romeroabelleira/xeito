defmodule Xeito.SkillKeywordsTest do
  @moduledoc "P4f step 3: keywords from a skill's frontmatter or an overlay file, and how the index weighs them."
  use ExUnit.Case, async: true

  alias Xeito.Skills
  alias Xeito.Skills.Index

  @moduletag :tmp_dir

  defp write_skill(dir, name, frontmatter) do
    path = Path.join([dir, ".agents/skills", name])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\nname: #{name}\n#{frontmatter}---\nbody\n")
  end

  describe "frontmatter/1: one nested level, for metadata" do
    test "indented keys under a key without a value are its map" do
      text = "---\nmetadata:\n  keywords: transcript, talk\n  author: 'someone'\nname: n\n---\nbody\n"

      assert {:ok, %{"metadata" => %{"keywords" => "transcript, talk", "author" => "someone"}, "name" => "n"}} =
               Skills.frontmatter(text)
    end

    test "a key without a value and nothing indented below stays empty" do
      assert {:ok, %{"metadata" => "", "name" => "n"}} = Skills.frontmatter("---\nmetadata:\nname: n\n---\n")
    end
  end

  describe "a skill's keywords" do
    test "come from metadata.keywords, a list or comma-separated", %{tmp_dir: dir} do
      write_skill(dir, "listed", "description: d\nmetadata:\n  keywords: [speaker, \"talk\"]\n")
      write_skill(dir, "commas", "description: d\nmetadata:\n  keywords: seam, interface ,\n")
      write_skill(dir, "none", "description: d\nmetadata:\n  author: x\n")
      write_skill(dir, "flat", "description: d\nmetadata: x\n")

      keywords = dir |> Skills.discover(home: dir, keywords: nil) |> Map.new(&{&1.name, &1.keywords})
      assert keywords == %{"listed" => ["speaker", "talk"], "commas" => ["seam", "interface"], "none" => [], "flat" => []}
    end

    test "an overlay file adds keywords to skills by name", %{tmp_dir: dir} do
      write_skill(dir, "youtube-transcript", "description: d\nmetadata:\n  keywords: video\n")
      write_skill(dir, "other", "description: d\n")

      overlay = Path.join(dir, "keywords.txt")

      File.write!(overlay, """
      # skills I cannot edit
      youtube-transcript: speaker, talk, video

      not-installed: x
      a line without a colon
      """)

      skills = Skills.discover(dir, home: dir, keywords: overlay)
      assert Enum.find(skills, &(&1.name == "youtube-transcript")).keywords == ["video", "speaker", "talk"]
      assert Enum.find(skills, &(&1.name == "other")).keywords == []
    end

    test "a missing overlay file adds nothing", %{tmp_dir: dir} do
      write_skill(dir, "other", "description: d\n")
      assert [%{keywords: []}] = Skills.discover(dir, home: dir, keywords: Path.join(dir, "missing.txt"))
    end

    test "Skills.overlay/1 reads the file into names and their keywords", %{tmp_dir: dir} do
      overlay = Path.join(dir, "keywords.txt")
      File.write!(overlay, "a: x, y\nb:z\n# c: w\n")
      assert Skills.overlay(overlay) == %{"a" => ["x", "y"], "b" => ["z"]}
      assert Skills.overlay(nil) == %{}
    end
  end

  describe "the index weighs keywords" do
    defp skill(name, description, keywords),
      do: %{name: name, description: description, dir: "/s/#{name}", model_invocation: true, keywords: keywords}

    test "one keyword of a skill shortlists it, as a word of its name does" do
      transcript = skill("youtube-transcript", "Fetch transcripts from YouTube videos.", ["speaker", "talk"])
      assert ["youtube-transcript"] = [transcript] |> Index.search("what does the speaker say?") |> Enum.map(& &1.name)
    end

    test "a keyword weighs more than a word of another skill's description" do
      skills = [
        skill("notes", "Keep notes on any speaker you meet.", []),
        skill("youtube-transcript", "Fetch transcripts from YouTube videos.", ["speaker"])
      ]

      assert ["youtube-transcript", "notes"] = skills |> Index.search("speaker", any: true) |> Enum.map(& &1.name)
    end

    test "keywords are normalised like the rest" do
      transcript = skill("youtube-transcript", "Fetch transcripts.", ["summarise"])
      assert [_] = Index.search([transcript], "summarizing please")
    end
  end
end
