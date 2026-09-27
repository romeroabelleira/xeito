defmodule Xeito.MachineTest do
  use ExUnit.Case, async: true

  alias Xeito.Machine
  alias Xeito.Machines.FixFailingTest

  defp compile(body) do
    name = "Xeito.MachineTest.M#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{name} do
      use Xeito.Machine, version: "0.0.1"
      #{body}
    end
    """)
  end

  test "compiles the DSL into plain data" do
    machine = Machine.fetch!(FixFailingTest)

    assert machine.name == "fix_failing_test"
    assert machine.version == "0.5.0"
    assert machine.initial == :reproduce
    assert Machine.children(machine, :working) == [:planning, :editing, :verifying]
    assert Machine.leaf(machine, :working) == :planning
    assert Machine.lineage(machine, :verifying) == [:verifying, :working]
    assert Machine.state!(machine, :triage).decision == Xeito.Decisions.Triage
    assert Machine.timeout(machine, :reproduce) == {900_000, :timeout}
    assert Machine.timeout(machine, :done) == nil
  end

  test "rejects a machine without a :failed final state" do
    assert_raise CompileError, ~r/final :failed/, fn ->
      compile("""
      initial :a
      state :a do
        on :go, to: :done
      end
      final :done
      """)
    end
  end

  test "rejects undeclared targets and missing functions" do
    error =
      assert_raise CompileError, fn ->
        compile("""
        initial :a
        state :a, entry: :nope do
          on :go, to: :nowhere, guard: :missing?
          on :stop, to: :failed
        end
        final :failed
        """)
      end

    assert error.description =~ "undeclared state :nowhere"
    assert error.description =~ "entry nope/1"
    assert error.description =~ "guard missing?/2"
  end

  test "rejects dead ends and unreachable states" do
    error =
      assert_raise CompileError, fn ->
        compile("""
        initial :a
        state :a do
          on :go, to: :b
        end
        state :b do
          on :again, to: :a
        end
        state :island do
          on :go, to: :failed
        end
        final :failed
        """)
      end

    assert error.description =~ ":island is unreachable"
    assert error.description =~ "no final state is reachable from :a"
  end

  test "requires compound states to name an initial child" do
    assert_raise CompileError, ~r/compound state :outer needs `initial:`/, fn ->
      compile("""
      initial :outer
      state :outer do
        state :inner do
          on :go, to: :failed
        end
      end
      final :failed
      """)
    end
  end

  test "requires decide states to name a decision type and handle all of its values" do
    assert_raise CompileError, ~r/:not_a_type is not a decision type/, fn ->
      compile("""
      initial :a
      state :a do
        decide :not_a_type
        on :go, to: :failed
      end
      final :failed
      """)
    end

    error =
      assert_raise CompileError, fn ->
        compile("""
        initial :a
        state :a do
          decide Xeito.Decisions.Done
          on {:decided, :done}, to: :finished
          on :go, to: :failed
        end
        final :finished
        final :failed
        """)
      end

    assert error.description =~ "does not handle {:decided, :continue}"
    assert error.description =~ "does not handle {:decided, :abstain}"
  end
end
