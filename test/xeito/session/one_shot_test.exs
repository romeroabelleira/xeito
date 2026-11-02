defmodule Xeito.Session.OneShotTest do
  use ExUnit.Case, async: true

  alias Xeito.Decision
  alias Xeito.Decision.Prompt
  alias Xeito.Decisions.Triage
  alias Xeito.Machines.Chat
  alias Xeito.Machines.RunTests
  alias Xeito.Machines.SelfRefine
  alias Xeito.Session.OneShot

  @moduletag :tmp_dir

  defp state(dir, chat \\ []),
    do: %{cwd: dir, history: [], system: "sys", chat: chat, max_steps: nil, test_cmd: "mix test"}

  defp skill(dir) do
    path = Path.join([dir, ".agents/skills/greet"])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\nname: greet\ndescription: Greet.\n---\nSay hello.\n")
  end

  defp write_skill(dir, name, front, body) do
    path = Path.join([dir, ".agents/skills", name])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\nname: #{name}\ndescription: D.\n#{front}---\n#{body}\n")
  end

  defp prepare!(text, opts, s) do
    {:ok, turn} = OneShot.prepare(text, opts, s)
    turn
  end

  describe "prepare/3: the machine, input and chat options of a one-shot turn" do
    test "neither a skill nor a machine: a chat turn of the text, without tools by default", %{tmp_dir: dir} do
      assert %{machine: Chat, reason: "one-shot", input: input, chat: []} = prepare!("hi", [], state(dir))
      assert %{prompt: "hi", tools: false, skill_candidates: []} = input
      refute Map.has_key?(input, :format)
    end

    test "tools: all of them, or only those listed", %{tmp_dir: dir} do
      refute Map.has_key?(prepare!("hi", [tools: true], state(dir)).input, :tools)
      assert %{tools: ["read"], skill_candidates: []} = prepare!("hi", [tools: ["read"]], state(dir)).input
      assert %{tools: ["read", "skill"]} = prepare!("hi", [tools: ["read", "skill"]], state(dir)).input

      assert {:error, "unknown tool \"fly\"; the tools are read, write, edit, bash, skill, fetch"} =
               OneShot.prepare("hi", [tools: ["read", "fly"]], state(dir))
    end

    test "a skill: its instructions with the text as the request, in a chat turn", %{tmp_dir: dir} do
      skill(dir)

      assert %{machine: Chat, input: input, reason: "one-shot skill:greet"} =
               prepare!("to Ana", [skill: "greet"], state(dir))

      assert input.prompt =~ "Say hello.\n\nRequest: to Ana"
      assert %{tools: false, skill_candidates: []} = input

      assert {:error, "no skill named \"nope\""} = OneShot.prepare("x", [skill: "nope"], state(dir))
    end

    test "a skill's variables are filled from vars:, and a missing one stops the turn before any call", %{tmp_dir: dir} do
      write_skill(dir, "greet", "metadata:\n  vars: lang=English, name\n", "Greet {{name}} in {{lang}}.")

      assert %{input: input, notices: []} = prepare!("hi", [skill: "greet", vars: %{"name" => "Ana"}], state(dir))
      assert input.prompt =~ "Greet Ana in English."

      assert {:error, "the skill greet needs a value for {{name}} (name=VALUE)"} =
               OneShot.prepare("hi", [skill: "greet"], state(dir))
    end

    test "a skill's off-box tier is refused by the default policy, with a notice; the call's own tier wins", %{
      tmp_dir: dir
    } do
      write_skill(dir, "far", "metadata:\n  tier: remote_frontier\n", "Far.")

      assert %{chat: chat, notices: [notice]} = prepare!("hi", [skill: "far"], state(dir))
      refute Keyword.has_key?(chat, :tier)
      assert notice =~ "the skill far asks for the remote_frontier tier, but the policy keeps local-only input"
      assert notice =~ "runs on local"

      # The call named a tier, so the skill's is not asked for: the error is about the call's.
      assert {:error, "nope is not a chat tier" <> _} = OneShot.prepare("hi", [skill: "far", tier: "nope"], state(dir))
    end

    test "a skill's output json:<type> is the answer format of a turn without tools; with tools, or an --as, it is not",
         %{tmp_dir: dir} do
      write_skill(dir, "judge", "metadata:\n  output: json:triage\n", "Judge.")
      schema = Prompt.json_schema(Decision.type!(Triage))

      assert %{input: %{format: ^schema}} = prepare!("x", [skill: "judge"], state(dir))
      assert %{input: input} = prepare!("x", [skill: "judge", tools: true], state(dir))
      refute Map.has_key?(input, :format)

      assert %{input: %{format: %{"type" => "object"}}} =
               prepare!("x", [skill: "judge", as: %{"type" => "object"}], state(dir))
    end

    test "named contexts follow the text: the call's, else the skill's; an unknown one is an error", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".agents/contexts"))
      File.write!(Path.join(dir, ".agents/contexts/house.md"), "Short sentences.\n")
      File.write!(Path.join(dir, ".agents/contexts/review.md"), "Check the tests.\n")
      write_skill(dir, "styled", "metadata:\n  contexts: house\n", "Write.")

      assert %{input: input} = prepare!("hi", [contexts: ["house", "review"]], state(dir))
      assert input.prompt == ~s(hi\n\nContext "house":\nShort sentences.\n\nContext "review":\nCheck the tests.)

      assert %{input: input} = prepare!("hi", [skill: "styled"], state(dir))
      assert input.prompt =~ "Request: hi\n\nContext \"house\":\nShort sentences."

      assert %{input: input} = prepare!("hi", [skill: "styled", contexts: ["review"]], state(dir))
      refute input.prompt =~ "Short sentences"

      assert {:error, "no context named \"nope\" in " <> _} = OneShot.prepare("hi", [contexts: ["nope"]], state(dir))
    end

    test "the self-refine machine, by name: the text as its request, under the session's system prompt", %{tmp_dir: dir} do
      assert %{machine: SelfRefine, input: input, reason: "one-shot machine:self_refine"} =
               prepare!("Condense this.", [machine: "self_refine"], state(dir))

      assert %{request: "Condense this.", system: "sys", cwd: ^dir} = input
    end

    test "reason: names the run, as /skill: does", %{tmp_dir: dir} do
      skill(dir)
      assert %{reason: "/skill:greet"} = prepare!("hi", [skill: "greet", reason: "/skill:greet"], state(dir))
    end

    test "a machine by name, with the input it needs; chat as a machine takes the tools", %{tmp_dir: dir} do
      assert %{machine: RunTests, input: %{test_cmd: "mix test"}, reason: "one-shot machine:run_tests"} =
               prepare!("", [machine: "run_tests"], state(dir))

      assert %{machine: Chat, input: %{tools: false}} = prepare!("hi", [machine: "chat"], state(dir))
      assert %{machine: Chat, input: %{tools: ["read"]}} = prepare!("hi", [machine: "chat", tools: ["read"]], state(dir))

      assert {:error, "unknown machine \"nope\"; available: " <> names} =
               OneShot.prepare("x", [machine: "nope"], state(dir))

      assert names =~ "run_tests"
    end

    test "a skill and a machine together are refused", %{tmp_dir: dir} do
      skill(dir)

      assert {:error, "a skill or a machine, not both"} =
               OneShot.prepare("x", [skill: "greet", machine: "chat"], state(dir))
    end

    test "as a decision type: its schema as the answer format, its instructions after the text", %{tmp_dir: dir} do
      type = Decision.type!(Triage)
      %{input: input} = prepare!("the test fails", [as: "triage"], state(dir))
      assert input.format == Prompt.json_schema(type)
      assert input.prompt == "the test fails\n\n" <> Prompt.instructions(type)
    end

    test "as a JSON Schema: the schema, and the model told to match it", %{tmp_dir: dir} do
      schema = %{"type" => "object", "properties" => %{"title" => %{"type" => "string"}}}
      %{input: input} = prepare!("a talk", [as: schema], state(dir))
      assert input.format == schema
      assert input.prompt == "a talk\n\nAnswer with JSON only, matching this JSON Schema:\n" <> JSON.encode!(schema)
    end

    test "an answer format needs a chat turn without tools, and a known type", %{tmp_dir: dir} do
      assert {:error, "unknown decision type \"nope\"; the types are " <> types} =
               OneShot.prepare("x", [as: "nope"], state(dir))

      assert types =~ "triage"
      assert {:error, "an answer format takes no tools"} = OneShot.prepare("x", [as: "triage", tools: true], state(dir))

      assert {:error, "only a chat turn has an answer format"} =
               OneShot.prepare("", [as: "triage", machine: "run_tests"], state(dir))
    end

    test "tier, model, temperature and thinking are the turn's chat options, over the session's", %{tmp_dir: dir} do
      opts = [model: "m1", temperature: 0.7, think: false]

      assert %{chat: chat} = prepare!("hi", opts, state(dir, tier: :local, keep: 1))

      assert Enum.sort(chat) ==
               Enum.sort(tier: :local, keep: 1, chat_model: "m1", model: "m1", temperature: 0.7, think: false)

      assert {:error, "nope is not a chat tier (one of: local, remote, remote_frontier)"} =
               OneShot.prepare("hi", [tier: "nope"], state(dir))
    end
  end

  describe "request/3: what the turn's first model call would send" do
    test "the exact messages, tools and answer format, with the tier", %{tmp_dir: dir} do
      assert {:ok, request} = OneShot.request("the test fails", [as: "triage"], state(dir, tier: :local))
      assert %{tier: :local, tools: [], format: %{"type" => "object"}} = request

      assert [%{role: "system", content: "sys" <> _}, %{role: "user", content: "the test fails\n\nDecision: " <> _}] =
               request.messages
    end

    test "nothing for a machine that is not chat, or what cannot start", %{tmp_dir: dir} do
      assert {:error, "run_tests sends no model request of its own; a dry run shows a chat turn's"} =
               OneShot.request("", [machine: "run_tests"], state(dir))

      assert {:error, "no skill named \"nope\""} = OneShot.request("x", [skill: "nope"], state(dir))
    end
  end
end
