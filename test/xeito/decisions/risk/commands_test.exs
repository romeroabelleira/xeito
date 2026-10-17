defmodule Xeito.Decisions.Risk.CommandsTest do
  use ExUnit.Case, async: true

  alias Xeito.Decisions.Risk.Commands

  defp effect(segment), do: Commands.effect(segment)

  test "reading commands read; the project's build and test commands too" do
    for segment <- [
          "ls -la",
          "cat a",
          "git status",
          "git blame a",
          "mix test",
          "npm run lint",
          "python3 -m pytest -q",
          "bundle exec rspec"
        ],
        do: assert(effect(segment) == :read, segment)
  end

  test "a command, subcommand or form not in the table is unknown" do
    for segment <- [
          "make",
          "git",
          "git push",
          "mix ecto.reset",
          "npm install",
          "python -m http.server",
          "",
          "bundle exec rake"
        ],
        do: assert(effect(segment) == :unknown, segment)
  end

  test "writers write the paths among their arguments, with short options only" do
    assert effect("rm -rf build tmp") == {:writes, ["build", "tmp"]}
    assert effect("tee -a log.txt") == {:writes, ["log.txt"]}
    assert effect("cp 'a b.txt' c.txt") == {:writes, ["a b.txt", "c.txt"]}
    assert effect("rm --verbose a") == :unknown
    assert effect("rm") == :unknown
    assert effect("rm $X") == :unknown
    assert Commands.writer?("rm")
    refute Commands.writer?("ls")
  end

  test "a flag that writes a file writes its value, however it is spelled" do
    assert effect("sort -o out.txt in.txt") == {:writes, ["out.txt"]}
    assert effect("sort -uo out.txt in.txt") == {:writes, ["out.txt"]}
    assert effect("sort -oout.txt in.txt") == {:writes, ["out.txt"]}
    assert effect("sort --output=out.txt in.txt") == {:writes, ["out.txt"]}
    assert effect("sort --out out.txt in.txt") == {:writes, ["out.txt"]}
    assert effect("sort -o a.txt -o b.txt in.txt") == {:writes, ["a.txt", "b.txt"]}
    assert effect("sort -r --reverse -o out.txt in.txt") == {:writes, ["out.txt"]}
    assert effect("git diff -p --stat --output=d.txt") == {:writes, ["d.txt"]}
    assert effect("tree -o out.txt lib") == {:writes, ["out.txt"]}
    assert effect("less -o log.txt a") == {:writes, ["log.txt"]}
    assert effect("less --LOG-FILE=log.txt a") == {:writes, ["log.txt"]}
    assert effect("git diff --output=d.txt") == {:writes, ["d.txt"]}
    assert effect("git log --output d.txt") == {:writes, ["d.txt"]}
    assert effect("sort -o") == :unknown
    assert effect("sort -o $OUT in.txt") == :unknown
  end

  test "uniq writes every name after its input; one or none, it reads" do
    assert effect("uniq in.txt out.txt") == {:writes, ["out.txt"]}
    assert effect("uniq -f 1 in.txt out.txt") == {:writes, ["in.txt", "out.txt"]}
    assert effect("uniq -c in.txt") == :read
    assert effect("uniq in.txt $OUT") == :unknown
  end

  test "flags that run a program, or write where the text does not say, win over the rest" do
    for segment <- [
          "rg --pre sh x",
          "rg -iz x",
          "sort --compress-program=gzip -o out.txt in",
          "git diff --ext-diff",
          "git log -p --textconv",
          "find . -execdir rm {} +",
          "find . -delete"
        ],
        do: assert(effect(segment) == :exec, segment)

    for segment <- ["tree -R -o x lib", "file -C -m magic", "find . -fprint list.txt"],
        do: assert(effect(segment) == :unknown, segment)

    for segment <- ["find . -okdir rm {} ;"], do: assert(effect(segment) == :exec, segment)
    for segment <- ["find . -fprint0 l", "find . -fprintf l %p"], do: assert(effect(segment) == :unknown, segment)

    assert effect("git diff --text a b") == :read
    assert effect("rg --pre-glob '*.pdf' x") == :read
  end

  test "sed: a line range reads, one plain substitution in place writes its files, anything else is unknown" do
    assert effect("sed -n 1,5p a.ex") == :read
    assert effect("sed -i 's/a/b/' a.ex b.ex") == {:writes, ["a.ex", "b.ex"]}
    assert effect("sed -i 's/a/b/w /tmp/x' a.ex") == :unknown
    assert effect("sed 's/a/b/' a.ex") == :unknown
    assert Commands.sed_writes(["-i", "-e", "s/a/b/", "x"]) == {:ok, ["x"]}
    assert Commands.sed_writes(["s/a/b/", "x"]) == :error
  end

  test "cd into a subdirectory reads; xargs is what it feeds, when that reads" do
    assert effect("cd lib") == :read
    assert effect("cd ..") == :unknown
    assert effect("xargs -0 grep -l x") == :read
    assert effect("xargs rm") == :unknown
    assert effect("xargs") == :unknown
  end

  test "git branch only lists" do
    assert effect("git branch -av") == :read
    assert effect("git branch --list 'f*'") == :read
    assert effect("git branch new") == :unknown
  end

  test "words: plain or single-quoted, globs only when allowed" do
    assert Commands.words("rm 'a b' c", :literal) == {:ok, ["rm", "a b", "c"]}
    assert Commands.words("rm *.ex", :literal) == :error
    assert Commands.words("rm *.ex", :glob) == {:ok, ["rm", "*.ex"]}
    assert Commands.words("rm $X", :glob) == :error
  end

  test "every record has a known class, handler or subcommands" do
    for {name, record} <- Commands.table(), do: assert(known?(record), name)
  end

  defp known?(%{subcommands: subs}), do: Enum.all?(Map.values(subs), &known?/1)
  defp known?(%{handler: h}), do: h in [:uniq, :sed, :cd, :xargs, :git_branch]

  defp known?(%{class: c} = r),
    do:
      c in [:read, :trusted, :write_args] and
        Enum.all?(Map.get(r, :cases, []), &(&1.class in [:exec, :unknown, :write_flag]))
end
