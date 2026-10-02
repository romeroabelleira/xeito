defmodule Xeito.ToolsTest do
  use ExUnit.Case, async: true

  alias Xeito.Effect
  alias Xeito.Tools

  defp effect(name, args, ctx \\ %{cwd: "/w"}), do: Tools.to_effect(%{name: name, arguments: args}, ctx)

  describe "to_effect/2" do
    test "read: a whole file, a symbol, an outline, a line range, or an earlier result" do
      assert {:ok, %Effect{kind: :read, args: %{path: "a.ex", cwd: "/w"}}} = effect("read", %{"path" => "a.ex"})
      assert {:ok, %Effect{args: %{symbol: "f/1"}}} = effect("read", %{"path" => "a.ex", "symbol" => "f/1"})
      assert {:ok, %Effect{args: %{outline: true}}} = effect("read", %{"path" => "a.ex", "outline" => true})
      assert {:ok, %Effect{args: %{lines: "3-9"}}} = effect("read", %{"path" => "a.ex", "lines" => "3-9"})
      assert {:ok, %Effect{args: %{result: "e4"}}} = effect("read", %{"result" => "e4"})
      assert {:ok, %Effect{args: %{path: "a.ex"} = args}} = effect("read", %{"path" => "a.ex", "symbol" => ""})
      refute Map.has_key?(args, :symbol)
    end

    test "write, edit and bash; writes into a protected directory are refused" do
      assert {:ok, %Effect{kind: :write}} = effect("write", %{"path" => "a.ex", "content" => "x"})
      assert {:ok, %Effect{kind: :edit}} = effect("edit", %{"path" => "a.ex", "old_text" => "x", "new_text" => "y"})
      assert {:ok, %Effect{kind: :bash, args: %{cmd: "ls"}}} = effect("bash", %{"command" => "ls"})
      assert {:error, "refused: deps/ " <> _} = effect("write", %{"path" => "deps/x/a.ex", "content" => "x"})

      assert {:error, "refused: .git/ " <> _} =
               effect("edit", %{"path" => ".git/config", "old_text" => "a", "new_text" => "b"})
    end

    test "the skill tool reads files of a skill the run offers, and only then" do
      ctx = %{cwd: "/w", skills: [%{name: "deploy", dir: "/skills/deploy"}]}

      assert {:ok, %Effect{kind: :read, args: %{path: "SKILL.md", cwd: "/skills/deploy"}}} =
               effect("skill", %{"name" => "deploy"}, ctx)

      assert {:ok, %Effect{args: %{path: "ref.md"}}} = effect("skill", %{"name" => "deploy", "file" => "ref.md"}, ctx)
      assert {:error, ~s(no skill named "other")} = effect("skill", %{"name" => "other"}, ctx)
      assert {:error, "unknown tool \"skill\"" <> _} = effect("skill", %{"name" => "deploy"})
    end

    test "bad arguments, an unknown tool, or no tools at all" do
      assert {:error, "invalid arguments for bash: %{}"} = effect("bash", %{})
      assert {:error, "invalid arguments for edit: " <> _} = effect("edit", %{"path" => "a.ex"})
      assert {:error, "invalid arguments for write: " <> _} = effect("write", %{"path" => "a.ex"})
      assert {:error, "invalid arguments for read: " <> _} = effect("read", %{})
      assert {:error, "unknown tool \"fly\"; available: read, write, edit, bash"} = effect("fly", %{})

      assert {:error, "no tools are available in this turn; answer in text"} =
               effect("bash", %{"command" => "ls"}, %{tools: false})
    end
  end

  test "result_text/1: what the model is told about each kind of result" do
    assert Tools.result_text(%{shaped: "short", exit_status: 0, output: "long"}) == "short"
    assert Tools.result_text(%{exit_status: 1, output: "boom"}) == "exit status 1\nboom"
    assert Tools.result_text(%{ok: true, content: "text"}) == "text"
    assert Tools.result_text(%{ok: true, syntax_error: "line 3"}) =~ "the file no longer parses: line 3"
    assert Tools.result_text(%{ok: true}) == "ok"
    assert Tools.result_text(%{ok: false, error: "missing"}) == "error: missing"
    assert Tools.result_text(%{ok: false, error: :enoent}) == "error: :enoent"
    assert Tools.result_text(%{something: 1}) == "%{something: 1}"
  end
end
