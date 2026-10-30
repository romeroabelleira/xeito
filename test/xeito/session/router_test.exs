defmodule Xeito.Session.RouterTest do
  use ExUnit.Case, async: true

  alias Xeito.Machines.Chat
  alias Xeito.Machines.Check
  alias Xeito.Machines.Commit
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Machines.RunTests
  alias Xeito.Session.Router

  @moduletag :tmp_dir

  test "route/2 picks the structured machines by intent and wording, free chat otherwise" do
    assert {FixFailingTest, _} = Router.route(:edit, "the login test is red")
    assert {Commit, _} = Router.route(:run, "commit my changes")
    assert {Check, _} = Router.route(:edit, "fix the credo warnings")
    assert {Check, _} = Router.route(:run, "run the linter")
    assert {RunTests, _} = Router.route(:run, "run the tests")
    assert {Chat, _} = Router.route(:question, "what does commit abc123 change?")

    # Writing a test, even one meant to fail first, is not fixing one.
    assert {Chat, _} = Router.route(:edit, "Write the failing test in tui_test.exs for banner/1.")
    assert {Chat, _} = Router.route(:edit, "add a red test for the parser, then make it pass")
    assert {Chat, _} = Router.route(:edit, "Develop the broken-link detector test-first")
    assert {FixFailingTest, _} = Router.route(:edit, "the checkout test fails, fix it")
  end

  test "the check commands come from the project's tasks, else are inferred from its files", %{tmp_dir: ws} do
    assert Router.check_command(ws) == "make test"
    assert Router.quick_check_command(ws) == nil
    File.write!(Path.join(ws, "Cargo.toml"), "")
    assert Router.quick_check_command(ws) == "cargo check"
    File.write!(Path.join(ws, "mix.exs"), "defp aliases, do: [ci: [\"test\"]]")
    assert Router.check_command(ws) == "mix ci"

    assert Router.quick_check_command(ws) ==
             "mix format --check-formatted && mix compile --warnings-as-errors"

    File.write!(Path.join(ws, "mix.exs"), ~s(defp aliases, do: ["check.quick": ["compile"]]))
    assert Router.quick_check_command(ws) == "mix check.quick"
  end
end
