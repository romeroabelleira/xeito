# 02 · State-machine core

[← Overview](00-overview.md) · Principles: [01](01-principles.md)

## Purpose

The core runs **machines**. A machine is a declarative, versioned statechart. The core gives each run its own supervised process, enforces guards, calls deciders, and emits one event per transition.

## Model: statecharts, executed by `gen_statem`

Xeito uses the Harel statechart vocabulary, the same one SCXML and XState use:

- **Hierarchical states.** `:working` contains `:planning`, `:editing` and `:verifying`. An event not handled in a child bubbles up to its parent.
- **Guards.** These are pure functions of `(state_data, event)`.
- **Entry/exit actions.** These are side effects, and they run only through *effects* (see below).
- **Internal transitions.** `on :steered, action: :steer` without `to:` updates the state data and stays: the state is neither left nor entered again, so its entry effects do not run twice and the effects in flight are still awaited. SCXML writes these as targetless transitions; the Mermaid export draws no edge for them. The chat machine takes a user's steering line this way (P4).
- **Timeouts.** These are the state, event and generic timeouts of `gen_statem`, and each one becomes a first-class `:timeout` event.
- **Final states.** Every machine has at least `:done` and `:failed`.
- **History and parallel regions.** Deferred until needed. Parallel regions are modelled as child runs instead (see "Composition").

The runtime is Erlang/OTP's `gen_statem` in `handle_event_function` mode. One generic module (`Xeito.Run`) interprets the compiled machine data. The statechart semantics live in a pure engine (`Xeito.Machine.Engine`) that the live run and log recovery share (Q1, decided in P1).
`gen_statem` already provides postponed events, state enter calls, timeouts and a fully inspectable state. That is most of a statechart runtime, already battle-tested.

### Machine definition (Elixir DSL)

```elixir
defmodule Xeito.Machines.FixFailingTest do
  use Xeito.Machine, version: "0.4.0"

  alias Xeito.Effect

  @tests_timeout 900_000
  @work_timeout 3_600_000

  initial :reproduce

  state :reproduce, entry: :run_tests, timeout: @tests_timeout do
    on :ran, to: :triage, guard: :failed?, action: :record_failure
    on :ran, to: :done
  end

  state :triage do
    decide Xeito.Decisions.Triage, input: :triage_input
    on {:decided, :flaky}, to: :rerun
    on {:decided, :code_bug}, to: :working, action: :record_triage
    on {:decided, :test_bug}, to: :working, action: :record_triage
    on {:decided, :env_problem}, to: :ask_human
    on {:decided, :abstain}, to: :ask_human
  end

  state :rerun, entry: :run_tests, timeout: @tests_timeout do
    on :ran, to: :done, guard: :passed?
    on :ran, to: :triage, guard: :reruns_left?, action: :count_rerun_and_record
    on :ran, to: :failed
  end

  state :working, initial: :planning do
    on :give_up, to: :failed

    # A human or external agent sends :planned/:edited; with `delegate: true` the entry
    # starts a child run of the free chat machine, which reports back as :child_done.
    state :planning, entry: :maybe_delegate, timeout: @work_timeout do
      on :planned, to: :editing
      on :child_done, to: :verifying, guard: :fixed_by_child?, action: :record_fix
      on :child_done, to: :ask_human, action: :record_fix
    end

    state :editing, timeout: @work_timeout do
      on :edited, to: :verifying
    end

    state :verifying, entry: :run_tests, timeout: @tests_timeout do
      on :ran, to: :done, guard: :passed?
      on :ran, to: :planning, guard: :attempts_left?, action: :count_attempt
      on :ran, to: :failed
    end
  end

  state :ask_human, timeout: 86_400_000 do
    on :answered, to: :working
    on :abort, to: :failed
  end

  final :done
  final :failed

  # Guards, actions, entry functions and decision inputs are ordinary public functions:
  def run_tests(ctx), do: [Effect.bash(Map.get(ctx, :test_cmd, "mix test"), cwd: ctx.cwd)]
  def failed?(_ctx, result), do: result.exit_status != 0
  def triage_input(ctx), do: %{test: ctx.test_name, output: ctx.last_failure, diff_stat: ctx.diff_stat}
  # …
end
```

This is the actual machine in `lib/xeito/machines/fix_failing_test.ex`. Guards, actions and entry functions are named by atom, so the definition stays data. Timeouts are `ms` or `{ms, event}`, and states without one get the machine's `default_timeout`. The DSL compiles to plain data (`%Xeito.Machine{}`). That data can be exported as **SCXML** or as **Mermaid** for documentation, and as a **Petri net** for conformance checking ([05](05-event-log-and-process-mining.md)).

<!-- generated: mix xeito.export Xeito.Machines.FixFailingTest -->
```mermaid
stateDiagram-v2
  [*] --> reproduce
  reproduce --> triage: ran [failed?]
  reproduce --> done: ran
  triage --> rerun: decided flaky
  triage --> working: decided code_bug
  triage --> working: decided test_bug
  triage --> ask_human: decided env_problem
  triage --> ask_human: decided abstain
  rerun --> done: ran [passed?]
  rerun --> triage: ran [reruns_left?]
  rerun --> failed: ran
  working --> failed: give_up
  working --> ask_human: child_done
  working --> done: ran [passed?]
  working --> failed: ran
  ask_human --> working: answered
  ask_human --> failed: abort
  state working {
    [*] --> planning
    planning --> editing: planned
    planning --> verifying: child_done [fixed_by_child?]
    editing --> verifying: edited
    verifying --> planning: ran [attempts_left?]
  }
  done --> [*]
  failed --> [*]
```

## Run lifecycle

```mermaid
sequenceDiagram
  participant U as User / TUI
  participant R as Run (gen_statem)
  participant D as Decider
  participant E as Effects (tools)
  participant L as Event log
  U->>R: start(machine, input)
  R->>L: run_started
  loop until final state
    R->>D: decide(type, context)   (only if the state declares a decision)
    D-->>R: %Decision{value, confidence}
    R->>L: decision_made
    R->>E: effect(:bash, "mix test")  (entry action)
    E-->>R: {:ran, result}
    R->>R: evaluate guards → pick transition
    R->>L: transition(from, event, to, actor)
  end
  R->>L: run_finished(status)
  R-->>U: result
```

## Effects are commands, not calls

Entry actions do not execute tools directly. They **return effect descriptions**, such as `{:effect, :bash, cmd: "mix test", timeout: 60_000}`, and an effect runner executes them.
When the runner finishes, it sends the result back to the run as an event.

This gives three properties for free:

1. **Replay.** In replay mode, the effect runner answers from the event log instead of executing anything, so a run can be stepped deterministically. See [06](06-observability.md).
2. **Sandboxing.** One choke point decides what is allowed. See [10](10-security-and-sandboxing.md).
3. **Testability.** Machines are tested with a fake runner. No mocks are needed inside the machine.

This is the "functional core, imperative shell" pattern, and the Elm / Redux-loop "commands" pattern, applied to agents.

## Composition

- **Sub-machines.** A state can `invoke` another machine. The child becomes a linked run whose final state arrives as an event in the parent (for example `{:child_done, :fix_test, result}`). This covers most "multi-agent" patterns without an agent framework.
- **Parallelism.** A parent invokes N children and waits for all of them (a guard counts completions). This is the natural fit for OTP: every child is a supervised process.
- **Machine registry.** Machines are identified by `{name, version}`. A run is pinned to the version it started with, so upgrades never change a running run.

## Supervision and durability

- `Xeito.RunSupervisor` (a `DynamicSupervisor`) starts one `gen_statem` per run.
- **Crash policy.** Every state declares `on_crash: :restart_state | :fail | :ask_human`. After a restart, the run rebuilds its data from the event log (event sourcing) and re-enters the current state.
- **Durable by construction.** Because the log holds every event, a machine that restarts after a reboot can resume where it stopped. Temporal offers this, but Temporal needs a server cluster; here it comes from a local append-only log.

## Invariants the core enforces

1. No transition happens without an event-log entry, written *before* the state change is acknowledged.
2. A decision can only produce values that label an outgoing transition of the current state. This is checked when the machine is compiled.
3. Every non-final state has a timeout, set explicitly or by default. No run waits forever.
4. Every machine has a reachable final state from every state. This is checked at compile time as a graph property.
5. Guards are pure. Enforcement is by convention plus a Credo check; the compiler cannot prove it.
