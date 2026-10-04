defmodule Mix.Tasks.Xeito.Skills.ExamplesTest do
  # Uses Mix's shell and the application's tier configuration.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Xeito.Skills.Examples, as: Task
  alias Xeito.Skills.Examples

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    tiers = Application.get_env(:xeito, :tiers)
    home = Application.get_env(:xeito, :state_home)
    Application.put_env(:xeito, :state_home, Path.join(dir, "home"))

    on_exit(fn ->
      Mix.shell(previous)
      restore(:tiers, tiers)
      restore(:state_home, home)
    end)

    skill = Path.join(dir, "ws/.agents/skills/youtube-transcript")
    File.mkdir_p!(skill)

    File.write!(
      Path.join(skill, "SKILL.md"),
      "---\nname: youtube-transcript\ndescription: Fetch transcripts.\n---\nBody\n"
    )

    %{ws: Path.join(dir, "ws")}
  end

  defp restore(key, nil), do: Application.delete_env(:xeito, key)
  defp restore(key, value), do: Application.put_env(:xeito, key, value)

  defp local(stub) do
    Req.Test.stub(stub, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{"models" => [%{"name" => "big", "digest" => "d1"}]})

        "/api/chat" ->
          Req.Test.json(conn, %{"message" => %{"content" => ~s({"requests": ["what does the speaker say?"]})}})
      end
    end)

    Application.put_env(:xeito, :tiers, local: [url: "http://#{stub}.test", plug: {Req.Test, stub}, model: "big"])
  end

  defp output do
    receive do
      {:mix_shell, :info, [text]} -> text
    after
      0 -> flunk("no output")
    end
  end

  test "writes the missing examples, then finds them up to date", %{ws: ws} do
    local(:task_examples)

    Task.run(["--cwd", ws])
    assert output() =~ "youtube-transcript: 1 example"

    Task.run(["--cwd", ws])
    assert output() == "the examples of 1 skill are up to date"
  end

  test "with a name, shows that skill's examples", %{ws: ws} do
    local(:task_show)
    Task.run(["--cwd", ws])
    output()

    Task.run(["--cwd", ws, "youtube-transcript"])
    assert output() == "youtube-transcript (1):\n  what does the speaker say?"

    Task.run(["--cwd", ws, "no-such-skill"])
    assert output() == "no examples for no-such-skill: is it a skill, and have its examples been written?"
  end

  test "without a local tier there is nothing to write them with", %{ws: ws} do
    Application.put_env(:xeito, :tiers, [])
    assert_raise Mix.Error, ~r/no local tier/, fn -> Task.run(["--cwd", ws]) end
    assert Examples.dir() =~ "home/.xeito/skills/examples"
  end
end
