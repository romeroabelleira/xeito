defmodule Mix.Tasks.Xeito.Skills.BenchTest do
  # Uses Mix's shell.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Xeito.Skills.Bench

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
  end

  defp output do
    receive do
      {:mix_shell, :info, [text]} -> text
    after
      0 -> flunk("no output")
    end
  end

  test "without arguments, measures the shipped sample" do
    Bench.run([])
    assert output() =~ ~r/^\d+ skills, \d+ cases: \d+ need a skill, \d+ need none\ntop 1: /
  end

  test "measures a set against the skills under --skills" do
    root = Path.join(System.tmp_dir!(), "xeito-bench-task-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "skills/web-search"))

    File.write!(
      Path.join(root, "skills/web-search/SKILL.md"),
      "---\nname: web-search\ndescription: Search the web for pages and extract their content.\n---\n"
    )

    set = Path.join(root, "set.jsonl")
    File.write!(set, ~s({"request": "search the web for elixir pages", "skill": "web-search"}\n))

    Bench.run([set, "--skills", Path.join(root, "skills")])
    assert output() =~ "1 skills, 1 cases: 1 need a skill, 0 need none\ntop 1: 1/1 (100%)"
  end

  test "a set without --skills runs against the user's skills" do
    set = Path.join(System.tmp_dir!(), "xeito-bench-task-#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(set) end)
    File.write!(set, ~s({"request": "search the web", "skill": "web-search"}\n))

    # Tests point the user's home nowhere, so the set's skill is not in the library.
    Bench.run([set])
    assert output() =~ "0 skills, 1 cases: 0 need a skill, 0 need none"
    assert Xeito.Skills.user_dir() == "/nonexistent/xeito-test-home/.agents/skills"
  end

  test "a missing set is an error" do
    assert_raise Mix.Error, ~r/no benchmark set/, fn -> Bench.run(["/nonexistent/set.jsonl"]) end
  end
end
