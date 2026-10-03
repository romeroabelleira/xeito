defmodule Xeito.Machine.ExportTest do
  use ExUnit.Case, async: true

  alias Xeito.Machine
  alias Xeito.Machine.Export
  alias Xeito.Machines.FixFailingTest

  @doc_path "docs/architecture/02-state-machine-core.md"
  @marker "<!-- generated: mix xeito.export Xeito.Machines.FixFailingTest -->"

  test "the diagram in the architecture doc is the generated one" do
    doc = File.read!(@doc_path)
    [_, after_marker] = String.split(doc, @marker, parts: 2)
    [_, block, _] = String.split(after_marker, ~r/```(mermaid)?\n/, parts: 3)

    assert block == Export.mermaid(Machine.fetch!(FixFailingTest)),
           "regenerate the diagram in #{@doc_path} with: mix xeito.export Xeito.Machines.FixFailingTest"
  end

  test "mermaid lifts cross-boundary transitions to the composite state" do
    mermaid = Export.mermaid(Machine.fetch!(FixFailingTest))

    assert mermaid =~ "state working {"
    assert mermaid =~ "    verifying --> planning: ran [attempts_left?]"
    assert mermaid =~ "  working --> done: ran [passed?]"
    assert mermaid =~ "  triage --> rerun: decided flaky"
    refute mermaid =~ "verifying --> done"
  end

  test "an internal transition is a targetless SCXML transition and no Mermaid edge" do
    machine = Machine.fetch!(Xeito.TestMachines.Counter)
    assert Export.scxml(machine) =~ ~s(<transition event="note"/>)
    refute Export.mermaid(machine) =~ "note"
  end

  test "scxml nests compound states and names guards as conditions" do
    scxml = Export.scxml(Machine.fetch!(FixFailingTest))

    assert scxml =~
             ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="fix_failing_test" initial="reproduce">)

    assert scxml =~ ~s(<state id="working" initial="planning">)
    assert scxml =~ ~s(<transition event="decided.flaky" target="rerun"/>)
    assert scxml =~ ~s(<transition event="ran" cond="passed?" target="done"/>)
    assert scxml =~ ~s(<final id="failed"/>)
  end
end
