defmodule Xeito.Tui.BannerTest do
  use ExUnit.Case, async: true

  alias Xeito.Tui.Banner

  describe "banner/2: the greeting above the session line" do
    test "keys, example prompts, the workspace's instructions and skills" do
      lines = Banner.banner("/w")

      assert lines == [
               "Enter sends · \\ Enter new line · Esc halts · Up/Down recall · Tab completes · Ctrl-J steers · Ctrl-T status bar · /help",
               "try: fix the failing test · run the checks · commit these changes · explain this code",
               "machines: chat · check · commit · fix_failing_test · run_tests · shell",
               "no AGENTS.md in /w",
               "no skills in /w",
               ""
             ]
    end

    @tag :tmp_dir
    test "the first lines of AGENTS.md, the workspace's skills by name, and how many of yours", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "AGENTS.md"), "# Notes\n\nline two\n\nline three\nline four\n")

      for {root, name} <- [
            {".agents/skills", "zz-tui-skill"},
            {"home/.agents/skills", "mine-a"},
            {"home/.agents/skills", "mine-b"}
          ] do
        skill = Path.join([dir, root, name])
        File.mkdir_p!(skill)
        File.write!(Path.join(skill, "SKILL.md"), "---\nname: #{name}\ndescription: a long description\n---\nbody\n")
      end

      assert Enum.drop(Banner.banner(dir, home: Path.join(dir, "home")), 3) == [
               "AGENTS.md: # Notes",
               "  line two",
               "  line three",
               "  … (#{Path.join(dir, "AGENTS.md")})",
               "skills here: /skill:zz-tui-skill · and 2 of yours (/skill: then Tab)",
               ""
             ]
    end

    @tag :tmp_dir
    test "only your own skills, or no directory at all", %{tmp_dir: dir} do
      skill = Path.join(dir, "home/.agents/skills/mine")
      File.mkdir_p!(skill)
      File.write!(Path.join(skill, "SKILL.md"), "---\nname: mine\ndescription: d\n---\n")

      File.write!(Path.join(dir, "AGENTS.md"), "\n  \n")
      lines = Banner.banner(dir, home: Path.join(dir, "home"))
      assert "no skills here · 1 of yours (/skill: then Tab)" in lines
      assert "AGENTS.md is empty (#{Path.join(dir, "AGENTS.md")})" in lines
      assert Enum.drop(Banner.banner(nil), 3) == ["no AGENTS.md", "no skills", ""]
    end
  end
end
