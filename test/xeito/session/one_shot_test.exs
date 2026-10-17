defmodule Xeito.Session.OneShotTest do
  use ExUnit.Case, async: true

  alias Xeito.Machines.Chat
  alias Xeito.Machines.RunTests
  alias Xeito.Session.OneShot

  @moduletag :tmp_dir

  defp state(dir), do: %{cwd: dir, history: [], system: "sys", chat: [], max_steps: nil, test_cmd: "mix test"}

  defp skill(dir) do
    path = Path.join([dir, ".agents/skills/greet"])
    File.mkdir_p!(path)
    File.write!(Path.join(path, "SKILL.md"), "---\nname: greet\ndescription: Greet.\n---\nSay hello.\n")
  end

  test "neither a skill nor a machine: a chat turn of the text, without tools by default", %{tmp_dir: dir} do
    assert {:ok, Chat, input, "one-shot"} = OneShot.input("hi", [], state(dir))
    assert %{prompt: "hi", tools: false, skill_candidates: []} = input
  end

  test "tools: all of them, or only those listed",
       %{tmp_dir: dir} do
    assert {:ok, Chat, input, _} = OneShot.input("hi", [tools: true], state(dir))
    refute Map.has_key?(input, :tools)

    assert {:ok, Chat, %{tools: ["read"], skill_candidates: []}, _} =
             OneShot.input("hi", [tools: ["read"]], state(dir))

    assert {:ok, Chat, %{tools: ["read", "skill"]}, _} = OneShot.input("hi", [tools: ["read", "skill"]], state(dir))

    assert {:error, "unknown tool \"fetch\"; the tools are read, write, edit, bash, skill"} =
             OneShot.input("hi", [tools: ["read", "fetch"]], state(dir))
  end

  test "a skill: its instructions with the text as the request, in a chat turn", %{tmp_dir: dir} do
    skill(dir)
    assert {:ok, Chat, input, "one-shot skill:greet"} = OneShot.input("to Ana", [skill: "greet"], state(dir))
    assert input.prompt =~ "Say hello.\n\nRequest: to Ana"
    assert %{tools: false, skill_candidates: []} = input

    assert {:error, "no skill named \"nope\""} = OneShot.input("x", [skill: "nope"], state(dir))
  end

  test "a machine by name, with the input it needs; chat as a machine takes the tools", %{tmp_dir: dir} do
    assert {:ok, RunTests, %{test_cmd: "mix test"}, "one-shot machine:run_tests"} =
             OneShot.input("", [machine: "run_tests"], state(dir))

    assert {:ok, Chat, %{tools: false}, "one-shot machine:chat"} = OneShot.input("hi", [machine: "chat"], state(dir))

    assert {:error, "unknown machine \"nope\"; available: " <> names} =
             OneShot.input("x", [machine: "nope"], state(dir))

    assert names =~ "run_tests"
  end

  test "a skill and a machine together are refused", %{tmp_dir: dir} do
    skill(dir)

    assert {:error, "a skill or a machine, not both"} =
             OneShot.input("x", [skill: "greet", machine: "chat"], state(dir))
  end
end
