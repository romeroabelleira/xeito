# 06 · Observability: step, trace, replay, benchmark

[← Overview](00-overview.md) · Reads: [05](05-event-log-and-process-mining.md) · UI: [07](07-harness-frontend.md)

Being able to *see* the underlying state machine is the point of Xeito. Observability has four verbs.

## 1. Trace

- **Persisted.** Every transition, effect and decision lands in the OCEL log ([05](05-event-log-and-process-mining.md)), the source of truth.
- **Live, for clients.** What a run appends to the log is also published on `Xeito.Events`, an in-process feed the daemon forwards to clients over its socket. The TUI's transcript and status line follow it, and a client that reconnects reads the log first.
- **Live, for handlers in the daemon.** `Xeito.Telemetry` emits a `:telemetry` event for each logged run event, right after the log write: `[:xeito, :run, :start]`, `[:xeito, :run, :transition]`, `[:xeito, :effect, :stop]`, `[:xeito, :decision, :stop]` (with confidence, latency, tokens, cost and energy as measurements) and `[:xeito, :run, :stop]`. Metrics and the exporter below attach to these. Telemetry is a projection of the log, never a separate truth. A run's input and an effect's result are left out, since a handler may send what it gets off the machine.
- **Interop.** An optional exporter maps runs to OpenTelemetry traces: run = trace, state = span, and model calls follow the OTel GenAI semantic conventions. Existing tools (Langfuse, Arize Phoenix, Jaeger) can then show Xeito runs next to other systems, without Xeito depending on any of them.

## 2. Step

Any machine can run in **step mode**. The run pauses before every transition and shows:

```
run 7 · fix_failing_test v0.3.0 · state :triage
  pending decision  Triage   (rules: no match)
  candidates        flaky | code_bug | test_bug | env_problem
  next decider      small (qwen3-1.7b, θ=0.80)
  [enter] step  [d] decide manually  [e] force escalate  [b] breakpoint  [q] abort
```

- **Breakpoints** can be set on states, decision types, low confidence (`conf < 0.6`), escalations, or guard rejections.
- **Manual decision.** The human answers the typed decision. The event is logged with `actor: :human`, which also produces a labelled example for [03](03-typed-decisions.md).

Implementation (P4): the run itself holds the next effect result instead of processing it, publishes a transient `paused` event, and processes it on `Xeito.Run.step/2`. That call can also replace a held decision with a human one (`actor: :human`, the model's answer kept as evidence).
Further results queue behind the held one. Breakpoints are `{:state, s}`, `{:decision, Type}` and `{:confidence_below, x}`.
Delegated child runs inherit the settings, and escalation runs never pause. No change to machines is needed. Clients use `/step`, `/next`, `/decide <value>`, `/continue` and `/break …`.

## 3. Replay

Because effects and decisions go through runners ([02](02-state-machine-core.md#effects-are-commands-not-calls)), a logged run can be re-executed with **recorded answers**:

| Mode | Decisions from | Effects from | Use |
|---|---|---|---|
| `exact` | log | log | debugging; time-travel through state data |
| `re-decide T` | live model for type T, log for the rest | log, until the path diverges | evaluate a new model or prompt for one decision type |
| `re-machine` | log where the state still exists | log, or live in a sandbox after divergence | evaluate a machine change |
| `live` | live | live, in a sandbox | reproduce a bug |

A **divergence** (the replayed path leaves the logged path) is itself the key output. It is reported as a diff of state sequences.

## 4. Benchmark

A **benchmark** is a fixed set of logged runs plus labelled decisions. The suite answers four questions:

- **Decision quality** per type and per decider: accuracy, macro-F1, calibration error (ECE), and abstention rate.
- **Cost:** latency p50/p95 per tier, tokens, currency, energy (estimated from RAPL on the CPU and from sysfs power on the GPU), and model swaps.
- **Process:** success rate, mean path length, rework loops, and the determinism budget ([01](01-principles.md#2-the-determinism-budget)).
- **Regressions:** counterfactual replay of vN+1 against vN on the same inputs. This is the gate in the meta machine's `benchmarking` state ([05](05-event-log-and-process-mining.md#the-meta-state-machine)).

Output formats: a TUI table, JSON, and a static HTML report. Benchmarks are designed to run on the reference workstation overnight ([09](09-reference-deployment.md#benchmark-protocol)).

## Views (web inspector)

The inspector is a local web app ([07](07-harness-frontend.md#web-inspector), [08](08-tech-stack.md)). Its views, in build order:

1. **Run timeline.** A swimlane per object type (run, decisions, model calls, tool calls).
2. **Machine view.** The declared statechart with live highlighting of the current state, and edge thickness showing transition frequency (a process map over the declared model).
3. **Step debugger.** The same controls as the TUI, plus a state-data inspector.
4. **Decision table.** All decisions of a type: filter, relabel, export to the eval set.
5. **Mining dashboard.** DFG and variants, conformance, bottlenecks, and the open proposals of the meta machine.
