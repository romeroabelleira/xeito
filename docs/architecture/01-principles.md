# 01 · Principles and glossary

[← Overview](00-overview.md)

## 1. The state-machine corset

A language model is a stochastic function. Asked the same open question twice, it may take two different paths, and nothing forces either path to be valid.
Xeito does not try to make the model deterministic. It makes the **space of consequences** deterministic:

- The **states** a task can be in are enumerated in code.
- The **transitions** out of each state are enumerated in code, and each one has a guard.
- A model is consulted only to **pick one legal transition**, or to produce an artefact that a guard then validates.
- Anything the model returns that does not fit the expected type is a *rejection*, not a surprise.
  A rejection is itself an event, and it has its own transition (retry, escalate, or fail).

The result is a system where the model's non-determinism is **bounded, observable and countable**.
Two runs of the same task may differ, but both are paths through the same known graph, so they can be compared.

> **Rule 1: Think in states before prompts.** For every task, first draw the machine: states, events, guards, terminal states.
> Only then decide which transitions need a model and which can be plain code.

## 2. The determinism budget

Every transition in a run is taken by exactly one kind of *actor*:

| Actor | Example | Deterministic? |
|---|---|---|
| `code` | "tests passed → `:done`" | yes |
| `human` | "user approved the diff" | no, but explicit |
| `small` | CPU model classifies the intent | stochastic, cheap |
| `large` | GPU 27B model plans an edit | stochastic, costly |
| `remote` | frontier API model | stochastic, costly, off-box |

The **determinism budget** is the share of transitions taken by `code`. It is reported per machine and per run.
A healthy machine drifts towards a higher `code` share over time: process mining shows which model decisions were always the same, and those become guards. See [05](05-event-log-and-process-mining.md).

> **Rule 2: Every model decision is a candidate for demotion to code.**

## 3. Typed decisions over free text

A decision is a function from context to a **closed type**: an enum, a tagged union, or a record with enumerated fields.
It carries a confidence score and a short rationale, and it is recorded. See [03](03-typed-decisions.md).
Free text is allowed only as *artefacts* (code, prose, commit messages). Artefacts are validated by guards; they never steer control flow directly.

> **Rule 3: Control flow is typed. Content is free.**

## 4. Delegation is a transition

Moving work from a small model to a larger one (or to a human) is a state change with a cost, a reason and a return path.
It is not a hidden retry loop. See [04](04-delegation.md).

> **Rule 4: Escalation is visible, priced and reversible.**

## 5. Observability is a feature, not a sidecar

A machine you cannot step through, replay and benchmark is a machine you cannot improve.
Every transition emits one event. The event log is the source of truth for debugging, evaluation and mining. See [06](06-observability.md).

> **Rule 5: If it isn't in the log, it didn't happen.**

## 6. Minimal surface

The harness follows pi's philosophy: few tools, a short system prompt, extensions over features, and the user in control.
Complexity lives in *machines* (data), not in the harness (code).

> **Rule 6: New behaviour is a new machine, not a new feature.**

## Glossary

| Term | Meaning |
|---|---|
| **Machine** | A versioned statechart definition (states, events, guards, actions). |
| **Run** | One execution of a machine; one Erlang process. |
| **Transition** | A state change `from --event[guard]/action--> to`, taken by one actor. |
| **Decision** | A typed choice made by a decider (code, model or human) inside a state. See [03](03-typed-decisions.md). |
| **Decider** | Anything that can produce a decision of a given type: a rule, a model tier, a human prompt. |
| **Tier** | A class of model decider: `small` (CPU), `large` (local GPU), `remote` (API). |
| **Escalation** | A transition that hands a decision to a higher tier. |
| **Guard** | A pure predicate that must hold for a transition to fire. |
| **Artefact** | Free-form output (code, text) produced in a state and checked by a guard. |
| **Event log** | Append-only OCEL 2.0 record of all transitions and decisions. |
| **Conformance** | How well the observed runs fit the declared machine. |
| **Determinism budget** | Share of transitions taken by `code` actors. |
| **Meta machine** | The machine that improves machines: mine → propose → review → release. |
