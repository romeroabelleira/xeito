defmodule Xeito.Machine.EngineTest do
  use ExUnit.Case, async: true

  alias Xeito.Machine
  alias Xeito.Machine.Engine
  alias Xeito.TestMachines.Counter

  setup do
    %{m: Machine.fetch!(Counter)}
  end

  test "start enters the initial configuration", %{m: m} do
    assert %{leaf: :idle, entered: [:idle], effects: []} = Engine.start(m, %{})
  end

  test "entering a compound state descends to its initial leaf and runs entry effects", %{m: m} do
    assert {:ok, step} = Engine.handle(m, :idle, %{}, :go, %{})
    assert step.to == :low
    assert step.exited == [:idle]
    assert step.entered == [:active, :low]
    assert [%Xeito.Effect{kind: :bash}] = step.effects
  end

  test "events bubble up to ancestors", %{m: m} do
    assert {:ok, %{from: :high, to: :done, exited: [:high, :active]}} =
             Engine.handle(m, :high, %{}, :stop, %{})
  end

  test "guards are tried in order; a self-transition exits and re-enters", %{m: m} do
    assert {:ok, step} = Engine.handle(m, :low, %{}, :up, %{})
    assert {step.to, step.exited, step.entered, step.ctx} == {:low, [:low], [:low], %{count: 1}}

    assert {:ok, %{to: :high}} = Engine.handle(m, :low, %{count: 2}, :up, %{})
    assert {:ok, %{to: :high}} = Engine.handle(m, :low, %{}, :up, %{force: true})
  end

  test "custom timeout events are ordinary transitions", %{m: m} do
    assert {:ok, %{to: :low, entered: [:low]}} = Engine.handle(m, :high, %{}, :cool_down, %{})
  end

  test "unknown events are ignored; an unhandled :timeout goes to :failed", %{m: m} do
    assert :ignored = Engine.handle(m, :idle, %{}, :bogus, %{})

    assert {:ok, %{to: :failed, implicit: true, exited: [:low, :active]}} =
             Engine.handle(m, :low, %{}, :timeout, %{})
  end

  test "final states ignore everything", %{m: m} do
    assert :ignored = Engine.handle(m, :done, %{}, :go, %{})
  end
end
