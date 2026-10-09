defmodule Xeito.Session.AllowedTest do
  use ExUnit.Case, async: true

  alias Xeito.Session.Allowed

  @moduletag :tmp_dir

  defp bash(command), do: %{"tool" => "bash", "arguments" => %{"command" => command}}
  defp file(cwd), do: Path.join([cwd, ".xeito", "allowed.json"])

  describe "the command a review is about" do
    test "a bash call's command" do
      assert Allowed.command(bash("mix ci")) == {:ok, "mix ci"}
    end

    test "a review that is not about a shell command has none" do
      assert Allowed.command(%{"tool" => "review", "summary" => "commit it"}) == :error
      assert Allowed.command(%{"tool" => "edit"}) == :error
      assert Allowed.command(%{"tool" => "bash", "arguments" => %{"command" => 3}}) == :error
      assert Allowed.command(nil) == :error
    end
  end

  describe "why a review can be skipped" do
    test "a command allowed for the session, one always allowed, one neither", %{tmp_dir: cwd} do
      {:ok, session} = Allowed.remember(:session, "mix ci", cwd, Allowed.new())
      {:ok, session} = Allowed.remember(:always, "git push", cwd, session)

      assert Allowed.scope(cwd, session, bash("mix ci")) == :session
      assert Allowed.scope(cwd, session, bash("git push")) == :always
      assert Allowed.scope(cwd, session, bash("git push --force")) == nil
      assert Allowed.scope(cwd, session, bash("mix ci && git push")) == nil
    end

    test "the session's allowances come before the workspace's", %{tmp_dir: cwd} do
      {:ok, _} = Allowed.remember(:always, "mix ci", cwd, Allowed.new())
      {:ok, session} = Allowed.remember(:session, "mix ci", cwd, Allowed.new())
      assert Allowed.scope(cwd, session, bash("mix ci")) == :session
    end

    test "a review that is not about a command is never skipped", %{tmp_dir: cwd} do
      {:ok, session} = Allowed.remember(:session, "commit it", cwd, Allowed.new())
      assert Allowed.scope(cwd, session, %{"tool" => "review", "summary" => "commit it"}) == nil
      assert Allowed.scope(cwd, session, nil) == nil
    end

    test "a command is matched exactly, as written", %{tmp_dir: cwd} do
      {:ok, session} = Allowed.remember(:session, "mix ci", cwd, Allowed.new())
      assert Allowed.scope(cwd, session, bash("mix ci ")) == nil
      assert Allowed.scope(cwd, session, bash("MIX CI")) == nil
    end
  end

  describe "remembering a command" do
    test "for the session: held in the set, nothing written", %{tmp_dir: cwd} do
      {:ok, session} = Allowed.remember(:session, "mix ci", cwd, Allowed.new())
      assert MapSet.member?(session, "mix ci")
      refute File.exists?(file(cwd))
      assert Allowed.always(cwd) == []
    end

    test "always: written to the workspace's .xeito/allowed.json, one entry per line", %{tmp_dir: cwd} do
      {:ok, session} = Allowed.remember(:always, "mix ci", cwd, Allowed.new())
      {:ok, ^session} = Allowed.remember(:always, "git push", cwd, session)
      assert session == Allowed.new()

      assert File.read!(file(cwd)) == ~s([\n  "mix ci",\n  "git push"\n]\n)
      assert Allowed.always(cwd) == ["mix ci", "git push"]
    end

    test "always: .xeito is kept out of the project's git, as the log keeps it", %{tmp_dir: cwd} do
      {:ok, _} = Allowed.remember(:always, "mix ci", cwd, Allowed.new())
      assert File.read!(Path.join([cwd, ".xeito", ".gitignore"])) == "*\n"

      # An existing .gitignore (the log's, or the user's own) is left alone.
      File.write!(Path.join([cwd, ".xeito", ".gitignore"]), "log.sqlite\n")
      {:ok, _} = Allowed.remember(:always, "git push", cwd, Allowed.new())
      assert File.read!(Path.join([cwd, ".xeito", ".gitignore"])) == "log.sqlite\n"
    end

    test "always: a command is written once, however often it is allowed", %{tmp_dir: cwd} do
      {:ok, session} = Allowed.remember(:always, "mix ci", cwd, Allowed.new())
      {:ok, _} = Allowed.remember(:always, "mix ci", cwd, session)
      assert Allowed.always(cwd) == ["mix ci"]
    end

    test "always: a command with quotes and newlines survives the round trip", %{tmp_dir: cwd} do
      command = ~s(sh -c 'echo "a"\necho b')
      {:ok, _} = Allowed.remember(:always, command, cwd, Allowed.new())
      assert Allowed.always(cwd) == [command]
    end

    test "always: the file cannot be written", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, ".xeito"), "not a directory")
      assert {:error, _reason} = Allowed.remember(:always, "mix ci", cwd, Allowed.new())
    end
  end

  describe "the workspace's always allowed commands" do
    test "none without the file, or with one that is not a list of commands", %{tmp_dir: cwd} do
      assert Allowed.always(cwd) == []

      File.mkdir_p!(Path.dirname(file(cwd)))
      File.write!(file(cwd), "not json")
      assert Allowed.always(cwd) == []

      File.write!(file(cwd), ~s({"mix ci": true}))
      assert Allowed.always(cwd) == []
    end

    test "entries that are not commands are skipped", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.dirname(file(cwd)))
      File.write!(file(cwd), ~s(["mix ci", 3, null, "git push"]))
      assert Allowed.always(cwd) == ["mix ci", "git push"]
    end
  end
end
