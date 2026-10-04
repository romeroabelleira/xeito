defmodule Xeito.SkillsPerTurnTest do
  @moduledoc "P4e: the project's skills are listed; at most one of the user's is chosen per turn."
  use ExUnit.Case, async: true

  alias Xeito.Decider
  alias Xeito.Decision
  alias Xeito.Decisions.Skill
  alias Xeito.Machine
  alias Xeito.Machine.Engine
  alias Xeito.Machines.Chat
  alias Xeito.Skills

  defp skill(name, description, dir \\ "/home/u/.agents/skills"),
    do: %{name: name, description: description, dir: Path.join(dir, name), model_invocation: true}

  defp library,
    do: [
      skill(
        "diagnosing-bugs",
        "Diagnosis loop for hard bugs and performance regressions. Use when the user says diagnose or debug."
      ),
      skill("code-review", "Review the changes since a fixed point along two axes: standards and spec."),
      skill("grill-me", "A relentless interview to sharpen a plan or design."),
      skill("youtube-transcript", "Fetch transcripts from YouTube videos for summarization and analysis."),
      skill("brave-search", "Web search and content extraction via Brave Search API.")
    ]

  describe "Skills.shortlist/2: the user's skills a turn may choose from (Xeito.Skills.Index)" do
    test "skills matching the request, the best first" do
      assert ["diagnosing-bugs"] =
               library() |> Skills.shortlist("please diagnose this performance regression") |> Enum.map(& &1.name)

      assert ["youtube-transcript"] =
               library() |> Skills.shortlist("summarise this youtube talk") |> Enum.map(& &1.name)
    end

    test "a request with nothing in common shortlists nothing" do
      assert Skills.shortlist(library(), "rename this module") == []
    end
  end

  describe "Skills.for_turn/3: what a chat turn lists and what it may choose from" do
    test "the workspace's skills are listed; the user's are only candidates, and only if they fit" do
      project = skill("release", "Cut a release: tag and changelog.", "/w/.agents/skills")
      manual = %{skill("teach", "Teach the user a new concept.") | model_invocation: false}

      assert %{listed: [^project], candidates: [%{name: "code-review"}]} =
               Skills.for_turn([project, manual | library()], "/w", "review the code changes since main")

      assert %{listed: [^project], candidates: []} = Skills.for_turn([project | library()], "/w", "rename this module")
    end
  end

  describe "the Skill decision: which candidate, if any" do
    defp input(request, candidates \\ ["diagnosing-bugs: Diagnosis loop.", "code-review: Review changes."]) do
      [first, second, third] = Enum.take(candidates ++ [nil, nil, nil], 3)
      %{request: request, first: first, second: second, third: third}
    end

    test "rules: no candidates is none; a request naming a candidate picks it" do
      type = Decision.type!(Skill)
      assert {:ok, :none, _} = Decider.apply_rules(type, input("rename this", []))
      assert {:ok, :second, _} = Decider.apply_rules(type, input("run a code review of my branch"))
      assert {:ok, :first, _} = Decider.apply_rules(type, input("use diagnosing-bugs on this crash"))
      assert :none = Decider.apply_rules(type, input("why does this crash"))
    end

    test "is a built-in type with labelled examples" do
      assert Skill in Xeito.Decisions.all()
      assert %{name: "skill", values: values} = Decision.type!(Skill)
      assert Keyword.keys(values) == [:first, :second, :third, :none]
    end
  end

  describe "the chat machine chooses a skill first" do
    defp ctx(extra \\ %{}), do: Map.merge(%{cwd: "/w", prompt: "diagnose this slow query", system: "s", steps: 0}, extra)

    @candidates [
      %{name: "diagnosing-bugs", description: "Diagnosis loop for hard bugs."},
      %{name: "code-review", description: "Review changes."}
    ]

    test "a turn starts by choosing a skill, from the candidates the session found" do
      assert Machine.fetch!(Chat).initial == :choosing_skill

      assert Chat.skill_input(ctx(%{skill_candidates: @candidates})) == %{
               request: "diagnose this slow query",
               first: "diagnosing-bugs: Diagnosis loop for hard bugs.",
               second: "code-review: Review changes.",
               third: nil
             }

      assert %{first: nil} = Chat.skill_input(ctx())
    end

    test "the chosen skill is suggested in the request, after it; none adds nothing" do
      machine = Machine.fetch!(Chat)
      chosen = ctx(%{skill_candidates: @candidates})

      assert {:ok, %{to: :thinking, ctx: with_skill}} =
               Engine.handle(machine, :choosing_skill, chosen, {:decided, :first}, %{})

      assert [%{role: "user", content: request}] =
               with_skill |> Chat.ask_model() |> hd() |> then(& &1.args.messages) |> Enum.take(-1)

      assert request =~
               ~r/\Adiagnose this slow query\n\n.*the skill tool.*diagnosing-bugs: Diagnosis loop for hard bugs\./s

      for value <- [:none, :abstain] do
        assert {:ok, %{to: :thinking, ctx: plain}} =
                 Engine.handle(machine, :choosing_skill, chosen, {:decided, value}, %{})

        assert [%{content: "diagnose this slow query"}] = Enum.take(hd(Chat.ask_model(plain)).args.messages, -1)
      end
    end

    test "a steer while choosing goes with the first model request" do
      machine = Machine.fetch!(Chat)

      assert {:ok, %{to: :choosing_skill, ctx: steered}} =
               Engine.handle(machine, :choosing_skill, ctx(), :steered, %{text: "use psql"})

      assert Enum.any?(hd(Chat.ask_model(steered)).args.messages, &(&1.content =~ "use psql"))
    end
  end
end
