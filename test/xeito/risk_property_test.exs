defmodule Xeito.RiskPropertyTest do
  @moduledoc "P4k step 6: properties of Risk's rules over generated commands, in a fixture workspace."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xeito.Decision.Eval.Fixtures
  alias Xeito.Decisions.Risk

  @programs ~w(ls cat head grep rg sort uniq tree less file find sed git touch mkdir rm mv cp tee echo chmod mkfs.ext4 curl make)
  @flags ~w(-la -n -f -rf -r -i -iz -o --pre --output=x.txt -D -delete -exec --force -p)
  @paths ~w(notes.txt lib/a.ex lib lib/*.ex draft.txt debug.log build build/cache/x big.bin out_dir/f.txt
            ../outside/f.txt / ~ /dev/sda 'notes.txt' .env .git/config new.txt)

  setup_all do
    root = Path.join(System.tmp_dir!(), "xeito-risk-props-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{cwd: Fixtures.build("project", root)}
  end

  defp segment do
    gen all(
          program <- member_of(@programs),
          sub <- one_of([constant(""), member_of(~w(branch diff log show status))]),
          flags <- list_of(member_of(@flags), max_length: 2),
          paths <- list_of(member_of(@paths), max_length: 2),
          redirect <- one_of([constant(""), member_of(["> out.txt", ">> notes.txt", "> build/x", "2>&1"])])
        ) do
      [program, if(program == "git", do: sub, else: "") | flags ++ paths ++ [redirect]]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
    end
  end

  defp command do
    gen all(
          first <- segment(),
          rest <- list_of(tuple({member_of([" ; ", " && ", " | ", "\n"]), segment()}), max_length: 2)
        ) do
      Enum.reduce(rest, first, fn {separator, next}, acc -> acc <> separator <> next end)
    end
  end

  # Severity: safe < review (no rule) < forbidden.
  defp rank(:safe), do: 0
  defp rank(nil), do: 1
  defp rank(:forbidden), do: 2

  defp verdict(command, cwd), do: Risk.classify(%{command: command, cwd: cwd})

  property "the rules answer every command, and never raise", %{cwd: cwd} do
    check all(command <- command()) do
      assert verdict(command, cwd) in [:safe, nil, :forbidden]
      assert Risk.undoable(%{command: command, cwd: cwd}) in [:safe, nil]
      assert is_boolean(Risk.repeatable?(command))
      assert match?({:ok, _}, Risk.written_paths(command)) or Risk.written_paths(command) == :error
    end
  end

  property "a command after another never lowers its verdict", %{cwd: cwd} do
    check all(a <- segment(), b <- segment(), separator <- member_of([" ; ", " && ", " | ", "\n"])) do
      joined = rank(verdict(a <> separator <> b, cwd))
      assert joined >= max(rank(verdict(a, cwd)), rank(verdict(b, cwd))), "#{inspect(a <> separator <> b)}"
    end
  end

  property "a dangerous command stays forbidden whatever comes after it", %{cwd: cwd} do
    dangerous =
      for ex <- Xeito.Decision.Eval.examples(Risk, workspaces: Path.join(Path.dirname(cwd), "examples")),
          ex.dangerous,
          do: ex.input.command

    check all(d <- member_of(dangerous), b <- segment(), separator <- member_of([" ; ", " && ", " || ", " | ", "\n"])) do
      assert verdict(d <> separator <> b, cwd) == :forbidden, inspect(d <> separator <> b)
    end
  end

  property "a write safe by rule is one undo covers", %{cwd: cwd} do
    check all(command <- command()) do
      with :safe <- verdict(command, cwd), {:ok, [_ | _] = paths} <- Risk.written_paths(command) do
        assert Xeito.Undo.covers?(cwd, paths), inspect(command)
      end
    end
  end

  property "a repeatable command is safe by rule and writes nothing", %{cwd: cwd} do
    check all(command <- command()) do
      if Risk.repeatable?(command) do
        assert verdict(command, cwd) == :safe, inspect(command)
        assert Risk.written_paths(command) == {:ok, []}, inspect(command)
      end
    end
  end

  property "quoting a plain word does not change the verdict", %{cwd: cwd} do
    check all(program <- member_of(~w(cat rm touch ls grep)), path <- member_of(~w(notes.txt lib/a.ex draft.txt new.txt))) do
      assert verdict("#{program} #{path}", cwd) == verdict("#{program} '#{path}'", cwd)
    end
  end
end
