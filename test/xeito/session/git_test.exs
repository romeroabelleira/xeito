defmodule Xeito.Session.GitTest do
  use ExUnit.Case, async: true

  alias Xeito.Session.Git

  test "parse/1: branch, changed entries, ahead and behind" do
    out =
      "# branch.oid abc\n# branch.head main\n# branch.upstream origin/main\n# branch.ab +2 -1\n1 .M N... a\n? new.txt\n"

    assert Git.parse(out) == %{branch: "main", dirty: 2, ahead: 2, behind: 1}

    assert Git.parse("# branch.head (detached)\n") == %{
             branch: "(detached)",
             dirty: 0,
             ahead: 0,
             behind: 0
           }
  end
end
