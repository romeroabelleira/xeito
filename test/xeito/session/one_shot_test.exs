defmodule Xeito.Session.OneShotTest do
  use ExUnit.Case, async: true

  alias Xeito.Decision
  alias Xeito.Decision.Prompt
  alias Xeito.Decisions.Triage
  alias Xeito.Machines.Chat
  alias Xeito.Machines.RunTests
  alias Xeito.Session.OneShot

  @moduletag :tmp_dir

  defp state(dir, chat \\ []),
    do: %{cwd: dir, history: [], system: "sys", chat: chat, max_steps: nil, test_cmd: "mix test"}

  defp skill(dir) do
    path = Path.join([dir, ".agents/skills/greet"])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\nname: greet\ndescription: Greet.\n---\nSay hello.\n")
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

      assert {:error, "unknown tool \"fetch\"; the tools are read, write, edit, bash, skill"} =
               OneShot.prepare("hi", [tools: ["read", "fetch"]], state(dir))
    end

    test "a skill: its instructions with the text as the request, in a chat turn", %{tmp_dir: dir} do
      skill(dir)

      assert %{machine: Chat, input: input, reason: "one-shot skill:greet"} =
               prepare!("to Ana", [skill: "greet"], state(dir))

      assert input.prompt =~ "Say hello.\n\nRequest: to Ana"
      assert %{tools: false, skill_candidates: []} = input

      assert {:error, "no skill named \"nope\""} = OneShot.prepare("x", [skill: "nope"], state(dir))
    end

    test "a machine by name, with the input it needs; chat as a machine takes the tools", %{tmp_dir: dir} do
      assert %{machine: RunTests, input: %{test_cmd: "mix test"}, reason: "one-shot machine:run_tests"} =
               prepare!("", [machine: "run_tests"], state(dir))

      assert %{machine: Chat, input: %{tools: false}} = prepare!("hi", [machine: "chat"], state(dir))

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
