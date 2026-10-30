defmodule Xeito.SkillsTest do
  use ExUnit.Case, async: true

  alias Xeito.Effects.Local
  alias Xeito.Skills
  alias Xeito.Tools

  @moduletag :tmp_dir

  defp skill(name, description, opts \\ []),
    do: %{
      name: name,
      description: description,
      dir: "/home/u/.agents/skills/#{name}",
      model_invocation: Keyword.get(opts, :model_invocation, true)
    }

  test "invocation/2: the skill's instructions and the request, as a chat turn's prompt", %{tmp_dir: dir} do
    path = Path.join([dir, ".agents/skills/greet"])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\nname: greet\ndescription: Greet.\n---\nSay hello.\n")
    [skill] = Skills.discover(dir, home: dir, keywords: nil)

    prompt = Skills.invocation(skill, "to Ana")
    assert prompt =~ ~s(Use the skill "greet". Its directory is #{path};)
    assert prompt =~ "Instructions:\n\nSay hello.\n\nRequest: to Ana\n"
    assert Skills.invocation(skill, "") =~ "Request: (none; follow the instructions)\n"
  end

  test "shortlist/2: ranks the skills the model may invoke, and leaves out the others" do
    library = [
      skill("youtube-transcript", "Fetch transcripts from YouTube videos for summarization and analysis."),
      skill("code-review", "Review the changes since a fixed point along two axes: standards and spec."),
      skill("brave-search", "Web search and content extraction via Brave Search API.")
    ]

    manual = skill("transcribe", "Fetch transcripts of YouTube videos.", model_invocation: false)

    assert ["youtube-transcript"] =
             [manual | library] |> Skills.shortlist("get the transcript of this youtube video") |> Enum.map(& &1.name)
  end

  test "from_dirs/1: loads every SKILL.md under the directories, sorted, the first of a name winning", %{tmp_dir: root} do
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

  test "skills are discovered in .agents/skills, project first, and read only inside their directory",
       %{tmp_dir: ws} do
    home = Path.join(ws, "home")

    write_skill = fn root, name, front ->
      dir = Path.join([root, name])
      File.mkdir_p!(Path.join(dir, "references"))
      File.write!(Path.join(dir, "SKILL.md"), "---\n#{front}\n---\n\n# #{name}\nDo the thing.\n")
      File.write!(Path.join(dir, "references/notes.md"), "notes of #{name}")
    end

    write_skill.(
      Path.join(ws, ".agents/skills"),
      "release",
      "name: release\ndescription: >\n  Cut a release:\n  tag and changelog."
    )

    write_skill.(
      Path.join(home, ".agents/skills"),
      "release",
      "name: release\ndescription: user copy"
    )

    write_skill.(
      Path.join(home, ".agents/skills/nested"),
      "pdf",
      "name: pdf\ndescription: \"Work with PDFs.\"\ndisable-model-invocation: true"
    )

    write_skill.(Path.join(ws, ".agents/skills"), "broken", "name: broken")

    # pi's own skill folders are not read: Xeito does not depend on another harness's skills.
    write_skill.(Path.join(ws, ".pi/skills"), "pi-project", "name: pi-project\ndescription: pi's")
    write_skill.(Path.join(home, ".pi/agent/skills"), "pi-user", "name: pi-user\ndescription: pi's")

    skills = Skills.discover(ws, home: home)
    assert Enum.map(skills, & &1.name) == ["release", "pdf"]

    # Without a home given, tests read no user skills at all: whatever skills the machine running
    # the suite has installed must not change what a session or the TUI sees.
    assert Enum.map(Skills.discover(ws), & &1.name) == ["release"]
    [release, pdf] = skills
    assert release.description == "Cut a release: tag and changelog."
    assert String.starts_with?(release.dir, ws <> "/.agents/skills")
    refute pdf.model_invocation
    assert Skills.body(release) =~ "Do the thing."

    section = Skills.prompt_section(skills)
    assert section =~ "- release: Cut a release" and not (section =~ "pdf")

    ctx = %{cwd: ws, skills: Enum.map(skills, &Map.take(&1, [:name, :dir]))}
    assert "skill" in Tools.names_for(ctx)

    {:ok, effect} =
      Tools.to_effect(
        %{name: "skill", arguments: %{"name" => "release", "file" => "references/notes.md"}},
        ctx
      )

    assert %{ok: true, content: "notes of release"} = Local.run(effect, [])

    {:ok, escape} =
      Tools.to_effect(
        %{name: "skill", arguments: %{"name" => "release", "file" => "../../../a.txt"}},
        ctx
      )

    assert %{ok: false, error: :outside_workspace} = Local.run(escape, [])

    assert {:error, "no skill named" <> _} =
             Tools.to_effect(%{name: "skill", arguments: %{"name" => "nope"}}, ctx)

    assert {:error, "unknown tool" <> _} =
             Tools.to_effect(%{name: "skill", arguments: %{"name" => "release"}}, %{cwd: ws})
  end
end
