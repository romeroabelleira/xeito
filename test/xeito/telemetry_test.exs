defmodule Xeito.TelemetryTest do
  use Xeito.Case, async: true

  alias Xeito.Effect
  alias Xeito.Effects.Fake
  alias Xeito.Log.Event
  alias Xeito.Machines.FixFailingTest
  alias Xeito.Machines.RunTests
  alias Xeito.Run
  alias Xeito.RunSupervisor
  alias Xeito.Telemetry

  @ctx %{cwd: "/tmp", test_cmd: "mix test"}

  # Handlers are global, so each test attaches its own and keeps only its run's events.
  setup do
    handler = "telemetry-test-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(handler, Telemetry.events(), &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def forward(name, measurements, metadata, test_pid), do: send(test_pid, {:telemetry, name, measurements, metadata})

  defp start(machine, runner) do
    {:ok, id} = RunSupervisor.start_run(machine, @ctx, run_id: run_id(), log: start_log!(), runner: runner)
    id
  end

  defp received(id) do
    eventually(fn -> Run.whereis(id) == nil end)
    collect(id, [])
  end

  defp collect(id, acc) do
    receive do
      {:telemetry, name, measurements, %{run_id: ^id} = metadata} -> collect(id, [{name, measurements, metadata} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  describe "a run" do
    test "emits its start, each transition, each completed effect and its end, in log order" do
      id = start(RunTests, scripted_runner([%{exit_status: 0, output: "ok"}]))

      assert [
               {[:xeito, :run, :start], %{}, %{machine: "run_tests", machine_version: _}},
               {[:xeito, :effect, :stop], %{}, %{effect_id: effect, kind: :bash}},
               {[:xeito, :run, :transition], %{}, %{from_state: :running, to_state: :done, actor: :code}},
               {[:xeito, :run, :stop], %{}, %{status: :done, final_state: :done}}
             ] = received(id)

      assert effect == "#{id}/e1"
    end

    test "emits each decision with its measurements" do
      decision = %{
        type: Xeito.Decisions.Triage,
        value: :env_problem,
        confidence: 0.8,
        actor: :local_decision,
        model: "small",
        latency_ms: 40,
        input_hash: "h",
        cost: %{tokens_in: 10, tokens_out: 1}
      }

      runner =
        {Fake,
         fun: fn
           %Effect{kind: :bash} -> %{exit_status: 1, output: "1 failure"}
           %Effect{kind: :decide} -> %{value: :env_problem, decision: decision}
         end}

      id = start(FixFailingTest, runner)

      assert_receive {:telemetry, [:xeito, :decision, :stop], measurements, %{run_id: ^id} = metadata}
      assert measurements == %{confidence: 0.8, latency_ms: 40, tokens_in: 10, tokens_out: 1}

      assert %{decision_type: "Xeito.Decisions.Triage", value: :env_problem, actor: :local_decision, model: "small"} =
               metadata
    end
  end

  describe "project/2" do
    test "a decision's confidence, latency, tokens, cost and energy are its measurements" do
      event =
        Event.new("decision_made", :term, %{
          "effect_id" => "r/e1",
          "decision_type" => "T",
          "value" => :yes,
          "actor" => :local_decision,
          "model" => "m",
          "confidence" => 0.9,
          "latency_ms" => 12,
          "tokens_in" => 30,
          "tokens_out" => 2,
          "usd" => 0.002,
          "joules_est" => 0.5
        })

      assert {[:xeito, :decision, :stop],
              %{confidence: 0.9, latency_ms: 12, tokens_in: 30, tokens_out: 2, usd: 0.002, joules_est: 0.5},
              %{run_id: "r", effect_id: "r/e1", decision_type: "T", value: :yes, actor: :local_decision, model: "m"}} =
               Telemetry.project("r", event)
    end

    test "a transition carries where it went, why, and who took it" do
      event =
        Event.new("transition", :term, %{
          "from_state" => :a,
          "to_state" => :b,
          "event_name" => :go,
          "actor" => :human,
          "implicit" => false
        })

      assert Telemetry.project("r", event) ==
               {[:xeito, :run, :transition], %{},
                %{run_id: "r", from_state: :a, to_state: :b, event_name: :go, actor: :human, implicit: false}}
    end

    # A handler may ship what it gets off the machine, so neither inputs nor results go out.
    test "leaves out a run's input and an effect's result" do
      started = Event.new("run_started", :term, %{"machine" => "m", "machine_version" => "1", "input" => %{secret: 1}})
      done = Event.new("effect_completed", :term, %{"effect_id" => "r/e1", "kind" => :read, "result" => "file text"})

      assert {_, _, %{run_id: "r", machine: "m", machine_version: "1"} = meta} = Telemetry.project("r", started)
      refute Map.has_key?(meta, :input)
      assert {_, _, meta} = Telemetry.project("r", done)
      assert meta == %{run_id: "r", effect_id: "r/e1", kind: :read}
    end

    test "events that are not projected give nil" do
      for type <- ~w(state_entered state_exited effect_requested event_received run_recovered),
          do: assert(Telemetry.project("r", %Event{type: type, term: :term}) == nil)
    end
  end
end
