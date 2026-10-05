defmodule Xeito.TaskRunnerTest do
  @moduledoc "A project's own task runner: just recipes and mise tasks name its test and check commands."
  # Sets which executables are installed (application environment).
  use ExUnit.Case, async: false

  alias Xeito.Session.Router
  alias Xeito.Session.TaskRunner

  @moduletag :tmp_dir

  setup do
    previous = Application.get_env(:xeito, :executables)
    on_exit(fn -> Application.put_env(:xeito, :executables, previous) end)
    installed(["just", "mise"])
  end

  defp installed(names),
    do: Application.put_env(:xeito, :executables, Map.new(["just", "mise"], &{&1, &1 in names && "/usr/bin/#{&1}"}))

  @justfile """
  # Tasks for this project
  set shell := ["bash", "-c"]
  alias t := test
  version := "1.0"

  test:
      ruby tests/all.rb

  # a recipe with parameters
  ci *args: test
      echo ci {{args}}

  @check-quick:
      ruby -c app/main.rb

  [private]
  helper:
      echo help
  """

  @mise """
  [tools]
  ruby = "3.4"
  test = "not a task"

  [tasks.test]
  run = "ruby tests/all.rb"

  [tasks."check-quick"]
  run = "ruby -c app/main.rb"

  [tasks]
  ci = "mise run test"

  [env]
  check = "not a task either"
  """

  test "just recipes, whatever the justfile's name", %{tmp_dir: dir} do
    for name <- ["justfile", "Justfile", ".justfile"] do
      ws = Path.join(dir, name)
      File.mkdir_p!(ws)
      File.write!(Path.join(ws, name), @justfile)

      assert TaskRunner.command(ws, ["test"]) == "just test"
      assert TaskRunner.command(ws, ["check", "ci"]) == "just ci"
      assert TaskRunner.command(ws, ["check-quick"]) == "just check-quick"
      assert TaskRunner.command(ws, ["version"]) == nil
      assert TaskRunner.command(ws, ["t"]) == nil
    end
  end

  test "mise tasks, as tables or in the tasks table, and nothing outside it", %{tmp_dir: dir} do
    for name <- ["mise.toml", ".mise.toml"] do
      ws = Path.join(dir, name)
      File.mkdir_p!(ws)
      File.write!(Path.join(ws, name), @mise)

      assert TaskRunner.command(ws, ["test"]) == "mise run test"
      assert TaskRunner.command(ws, ["check-quick"]) == "mise run check-quick"
      assert TaskRunner.command(ws, ["check", "ci"]) == "mise run ci"
      assert TaskRunner.command(ws, ["ruby"]) == nil
    end
  end

  test "just first; a runner that is not installed is passed over", %{tmp_dir: ws} do
    File.write!(Path.join(ws, "justfile"), "test:\n    echo just\n")
    File.write!(Path.join(ws, "mise.toml"), "[tasks.test]\nrun = \"echo mise\"\n")
    assert TaskRunner.command(ws, ["test"]) == "just test"

    installed(["mise"])
    assert TaskRunner.command(ws, ["test"]) == "mise run test"

    installed([])
    assert TaskRunner.command(ws, ["test"]) == nil
  end

  test "a workspace without either has no task", %{tmp_dir: ws} do
    assert TaskRunner.command(ws, ["test"]) == nil
  end

  test "the router prefers the project's own tasks to what its build files suggest", %{tmp_dir: ws} do
    File.write!(Path.join(ws, "mix.exs"), "defp aliases, do: [ci: [\"test\"]]")
    assert Router.test_command(ws) == "mix test"
    assert Router.check_command(ws) == "mix ci"

    File.write!(
      Path.join(ws, "mise.toml"),
      ~s([tasks.test]\nrun = "x"\n[tasks.check]\nrun = "x"\n[tasks.check-quick]\nrun = "x"\n)
    )

    assert Router.test_command(ws) == "mise run test"
    assert Router.check_command(ws) == "mise run check"
    assert Router.quick_check_command(ws) == "mise run check-quick"
  end
end
