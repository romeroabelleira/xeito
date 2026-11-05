defmodule Xeito.Scripts.ApiTest do
  # The API runs inside a script: each test evaluates one through the VM, with the runner's
  # answers stubbed as JSON carries them. One script runs at a time in a VM: not async.
  use ExUnit.Case, async: false

  alias Xeito.Scripts.Api
  alias Xeito.Scripts.Vm

  # Evaluates `code` with `answers` (call name => the runner's reply) and gives the script's value.
  defp eval(code, answers) do
    on_call = fn name, _args -> Map.fetch!(answers, name) end
    assert {:ok, value, _stdio} = Vm.run(code, %{}, on_call)
    value
  end

  defp failure(code, answers) do
    on_call = fn name, _args -> Map.fetch!(answers, name) end
    assert {:error, failure} = Vm.run(code, %{}, on_call)
    failure
  end

  @refused %{"ok" => false, "error" => "not run: it would need a review"}

  describe "a call that can fail gives {:ok, value} or {:error, reason}" do
    test "read gives the file's text" do
      assert {:ok, "defmodule A"} =
               eval(~s|Script.read("a.ex")|, %{"read" => %{"ok" => true, "content" => "defmodule A"}})

      assert {:error, "enoent"} = eval(~s|Script.read("nope")|, %{"read" => %{"ok" => false, "error" => "enoent"}})
    end

    test "bash gives the output of a command that exits 0, else its exit status with the output" do
      assert {:ok, "a.ex\n"} = eval(~s|Script.bash("ls")|, %{"bash" => %{"exit_status" => 0, "output" => "a.ex\n"}})

      assert {:error, %{exit_status: 1, output: ""}} =
               eval(~s|Script.bash("grep x f")|, %{"bash" => %{"exit_status" => 1, "output" => ""}})

      assert {:error, "not run: it would need a review"} = eval(~s|Script.bash("npm install")|, %{"bash" => @refused})
    end

    test "mcp gives the tool's text" do
      assert {:ok, "hi"} = eval(~s|Script.mcp("fx", "echo", %{})|, %{"mcp" => %{"ok" => true, "content" => "hi"}})

      assert {:error, "no MCP tool fx.nope"} =
               eval(~s|Script.mcp("fx", "nope", %{})|, %{"mcp" => %{"ok" => false, "error" => "no MCP tool fx.nope"}})
    end

    test "an answer the API does not know is an error naming it" do
      assert {:error, "unexpected answer: " <> rest} = eval(~s|Script.read("a.ex")|, %{"read" => %{"what" => 1}})
      assert rest =~ "what"
      assert {:error, "unexpected answer: " <> _} = eval(~s|Script.bash("ls")|, %{"bash" => "garbage"})
      assert {:error, "unexpected answer: " <> _} = eval(~s|Script.classify(%{}, %{})|, %{"classify" => "garbage"})
      assert {:error, "unexpected answer: " <> _} = eval(~s|Script.decide("t", %{})|, %{"decide" => "garbage"})
    end
  end

  describe "a call that only changes something gives :ok or {:error, reason}" do
    test "write, edit and remember" do
      assert :ok = eval(~s|Script.write("a.txt", "one")|, %{"write" => %{"ok" => true}})
      assert :ok = eval(~s|Script.edit("a.txt", "one", "two")|, %{"edit" => %{"ok" => true}})
      assert :ok = eval(~s|Script.remember("issue:1", %{"type" => "issue"})|, %{"remember" => %{"ok" => true}})

      refused = %{"ok" => false, "error" => "refused: deps/ is managed"}
      assert {:error, "refused: deps/ is managed"} = eval(~s|Script.write("deps/x", "x")|, %{"write" => refused})

      assert {:error, "old_text not found"} =
               eval(~s|Script.edit("a", "b", "c")|, %{"edit" => %{"ok" => false, "error" => "old_text not found"}})
    end
  end

  describe "decisions come back with atom keys" do
    @verdict %{
      "value" => "flaky",
      "confidence" => 0.9,
      "actor" => "local_decision",
      "model" => "m",
      "probabilities" => %{"flaky" => 0.9}
    }

    test "decide gives the verdict, or the reason none was made" do
      assert {:ok,
              %{value: "flaky", confidence: 0.9, actor: "local_decision", model: "m", probabilities: %{"flaky" => 0.9}}} =
               eval(~s|Script.decide("triage", %{})|, %{"decide" => @verdict})

      assert {:error, "no tier could decide"} =
               eval(~s|Script.decide("triage", %{})|, %{
                 "decide" => %{"value" => "abstain", "error" => "no tier could decide"}
               })

      assert {:error, "unknown decision type" <> _} =
               eval(~s|Script.decide("nope", %{})|, %{
                 "decide" => %{"ok" => false, "error" => "unknown decision type nope"}
               })
    end

    test "classify gives one verdict per question, by the question's name" do
      answers = %{"urgency" => @verdict, "fixable" => %{"value" => "yes", "confidence" => 0.7}}

      assert {:ok,
              %{
                "urgency" => %{value: "flaky", probabilities: %{"flaky" => 0.9}},
                "fixable" => %{value: "yes", confidence: 0.7}
              }} =
               eval(~s|Script.classify(%{}, %{})|, %{"classify" => answers})

      assert {:error, "urgency: unknown question type"} =
               eval(~s|Script.classify(%{}, %{})|, %{
                 "classify" => %{"ok" => false, "error" => "urgency: unknown question type"}
               })
    end
  end

  describe "a call that cannot fail gives its value, and raises only when the script was stopped" do
    test "text, now, random and search_tools" do
      assert "hi" = eval(~s|Script.text("hi")|, %{"text" => "hi"})
      assert 1_700_000_000_000 = eval("Script.now()", %{"now" => 1_700_000_000_000})
      assert 0.5 = eval("Script.random()", %{"random" => 0.5})

      tools = [%{"server" => "fx", "name" => "echo", "description" => "does echo", "schema" => %{"type" => "object"}}]

      assert [%{server: "fx", name: "echo", description: "does echo", schema: %{"type" => "object"}}] =
               eval(~s|Script.search_tools("echo")|, %{"search_tools" => tools})
    end

    test "a stopped script's calls raise with the reason, so the script fails naming it" do
      stopped = %{"ok" => false, "error" => "stopped: `rm -rf ~/` is forbidden"}

      for code <- ["Script.now()", "Script.random()", ~s|Script.text("x")|, ~s|Script.search_tools("x")|] do
        assert %{type: :exception, message: message} =
                 failure(code, %{"now" => stopped, "random" => stopped, "text" => stopped, "search_tools" => stopped})

        assert message =~ "(RuntimeError) stopped: `rm -rf ~/` is forbidden", code
      end
    end
  end

  test "parallel maps in order, for now" do
    assert [2, 4] = eval("Script.parallel([1, 2], &(&1 * 2), max: 4)", %{})
  end

  test "shapes/0 numbers the result shapes, for the sandbox fingerprint" do
    assert Api.shapes() == 2
  end
end
