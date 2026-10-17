defmodule Xeito.SkillsTest do
  use ExUnit.Case, async: true

  alias Xeito.Skills

  @moduletag :tmp_dir

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
end
