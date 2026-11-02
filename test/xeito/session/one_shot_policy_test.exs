defmodule Xeito.Session.OneShotPolicyTest do
  # Sets the application's policy and tiers, which every test reads: not async.
  use ExUnit.Case, async: false

  alias Xeito.Session.OneShot

  @moduletag :tmp_dir

  setup do
    saved = for key <- [:policy, :tiers], do: {key, Application.get_env(:xeito, key)}
    Application.put_env(:xeito, :policy, locality: :public)

    Application.put_env(:xeito, :tiers,
      local: [url: "http://l.test", model: "m"],
      remote_frontier: [url: "http://f.test", model: "f", api_key: "k"]
    )

    on_exit(fn ->
      for {key, value} <- saved,
          do: if(value, do: Application.put_env(:xeito, key, value), else: Application.delete_env(:xeito, key))
    end)
  end

  defp write_skill(dir, name, tier) do
    path = Path.join([dir, ".agents/skills", name])
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, "SKILL.md"),
      "---\nname: #{name}\ndescription: D.\nmetadata:\n  tier: #{tier}\n---\nBody.\n"
    )
  end

  test "a skill's tier applies when the tier is configured: a local one always, an off-box one where the policy lets input leave the machine",
       %{tmp_dir: dir} do
    write_skill(dir, "near", "local")
    write_skill(dir, "far", "remote_frontier")
    s = %{cwd: dir, history: [], system: "sys", chat: [], max_steps: nil, test_cmd: "mix test"}

    assert {:ok, %{chat: chat, notices: []}} = OneShot.prepare("hi", [skill: "near"], s)
    assert chat[:tier] == :local

    assert {:ok, %{chat: chat, notices: []}} = OneShot.prepare("hi", [skill: "far"], s)
    assert chat[:tier] == :remote_frontier
  end
end
