# 05 · Event log and process mining

[← Overview](00-overview.md) · Consumes: [02](02-state-machine-core.md), [03](03-typed-decisions.md), [04](04-delegation.md) · Feeds: [06](06-observability.md)

## Why process mining

Process mining extracts the **actual** process model from event logs, and compares it with the **intended** one (van der Aalst).
An agent harness produces exactly that kind of data: timestamped, case-structured events.
Xeito uses the discipline in two directions:

1. **Inward (meta).** Mine Xeito's own runs to see how machines really behave. Where do runs loop, stall, escalate or diverge from the declared statechart?
2. **Outward (product).** For any task the user brings, mine or sketch its process *before* automating it: "think about the task as a state machine first" ([01](01-principles.md)).

## Event log format: OCEL 2.0

A classic process-mining log (XES, IEEE 1849) assumes one *case* per event. Agent runs are not that simple.
A single `decision_made` event relates to a run, a decision, a model call and several files at once.
**OCEL 2.0** (Object-Centric Event Log) models this natively: each event references many objects of many types, and objects have their own attributes and relations.

### Object types

| Object type | Key attributes |
|---|---|
| `run` | machine, machine_version, input_hash, status |
| `machine` | name, version |
| `decision` | type, type_version, value, confidence, actor |
| `model_call` | tier, model, tokens_in/out, latency_ms, cost |
| `file` | path (hashed for private repos), language |
| `tool_call` | tool, exit_status, duration_ms |
| `user` | local id only |

### Event types

`run_started`, `state_entered`, `state_exited`, `decision_requested`, `decision_made`, `escalated`, `effect_requested`, `effect_completed`, `guard_rejected`, `human_prompted`, `human_answered`, `model_swapped`, `run_finished`.

Each event carries `(id, type, time, attributes, [{object_id, qualifier}])`, for example `{decision:42, "decides"}` and `{run:7, "within"}`.

### Storage

- **Hot:** an append-only log per run, kept in the Elixir node (ETS for the run, flushed to disk).
- **Durable:** **SQLite**, using the OCEL 2.0 SQLite relational layout, so PM4Py and other tools can read it directly. This means no export step, and a single file per workspace (`.xeito/log.sqlite`).
- **Optional:** export to OCEL JSON, flattened XES per object type, and OpenTelemetry spans ([06](06-observability.md)).

#### Storing inputs, not state

The log applies the central idea of fighting games' rollback netcode: the machines are deterministic, so the log records *inputs* once (model replies, tool output, human answers) and treats everything derived from them as recomputable. `Xeito.Log.Store` implements this without changing what readers see.

- **Message chains.** Each chat message is stored once in `xeito_message` and points to its parent. A message's id hashes its parent's id and its own content, so the id of a chain's last message is a checksum of the conversation up to it, and shared prefixes (system prompt, earlier turns) are stored once. Messages are stored as JSON, so any SQLite tool can read a conversation. A message that JSON cannot reproduce exactly also keeps its Erlang term. An event that carries a message list stores `{:xeito_chain, head, count}` instead. Its OCEL attribute shows `{"chain": head, "messages": count}`, so mining tools see the shape of a conversation without its text.
- **Results once.** The event that an effect's result produces refers to the `effect_completed` event instead of repeating its payload.
- **Compressed terms.** Terms are stored with compression, and small terms stay uncompressed.
- **Replay checks itself.** Like rollback's state checksums, recovery compares every effect the replay requests with the one the log recorded. For a chat call, that is the exact message chain the model saw. The first mismatch is reported as a desync, and the run refuses to recover from it instead of sending a different request. `mix xeito.log verify` runs this check over a whole log.

As a result, the log grows linearly with conversation length, not quadratically: in a synthetic chat run with 40 model calls, the payload drops from 1.4 MB to 49 KB. Logs written before this layout read unchanged, and `mix xeito.log compact` rewrites them.

## Mining pipeline

```mermaid
flowchart LR
  L[(OCEL 2.0<br/>SQLite)] --> F[Flatten per<br/>object type]
  F --> D[Discovery<br/>DFG · Inductive Miner]
  L --> C[Conformance<br/>declared machine → Petri net<br/>alignments / token replay]
  D --> V[Variants &<br/>bottlenecks]
  C --> V
  V --> P[Proposals]
  P --> H{Human review}
  H -->|accept| M[New machine version]
  H -->|reject| A[Archive with reason]
  M --> L
```

- **Discovery.** Directly-follows graphs (DFGs) for a quick look. Inductive Miner produces sound process trees and Petri nets. Object-centric DFGs across runs, decisions and model calls.
- **Conformance.** Each machine compiles to a Petri net ([02](02-state-machine-core.md)). Replaying the logged runs against it gives *fitness*, which should be 1.0 by construction since the core enforces transitions. Fitness below 1.0 means a bug or a hand-edited log.
  The more interesting measures are **precision** (does the declared machine allow many paths that never occur, so it could be simpler?) and conformance against *intended* models: the sketched process a user drew for a task, compared with what the agent did.
- **Performance.** Sojourn time per state, waiting time for effects, escalation frequency per decision type, rework loops (`verifying → planning` cycles), and model-swap overhead.
- **Decision mining.** For each decision type, learn which input features predict the committed value. This is how typed decisions graduate to classifiers or rules ([03](03-typed-decisions.md#three-families-of-small-decider)).

Tooling: **PM4Py** runs in a Python sidecar, invoked as a batch job over the SQLite file. It never sits in the hot path. Elixir-native DFG and variant computation cover the live inspector ([06](06-observability.md)). Nothing heavier is ported to Elixir.

## The meta state machine

The improvement process is a state machine, and it is logged like any other machine, so it is mined too:

```mermaid
stateDiagram-v2
  [*] --> collecting
  collecting --> mining: N runs or weekly
  mining --> proposing: findings ≥ 1
  mining --> collecting: nothing new
  proposing --> reviewing
  reviewing --> benchmarking: accepted
  reviewing --> collecting: rejected (reason logged)
  benchmarking --> releasing: counterfactual replay ≥ baseline
  benchmarking --> proposing: regression
  releasing --> collecting: machine vN+1 active
```

### Kinds of proposal

| Finding | Proposal |
|---|---|
| A decision is always the same value given feature X | Replace it with a rule (raise the determinism budget) |
| `small` is overridden by `large` more than 30% of the time for a type | Add examples, raise θs, or fine-tune |
| `large` agrees with `small` more than 95% of the time when escalated | Lower θs (save cost) |
| A loop `verifying → planning` more than 3× is common | Add a `:rethink` state that escalates the plan |
| A state is never entered | Remove it (precision) |
| Frequent human override at a state | Make that state ask *before* acting |
| The model-swap state takes more than 20% of wall-clock | Batch decisions by model; change the default large model |

Proposals are **diffs to machine definitions or decision policies**, never to prompts alone. Each diff is benchmarked by counterfactual replay ([06](06-observability.md#4-benchmark)) before a human accepts it.

A later step (P7 in the [implementation plan](../implementation-plan.md)) lets the large or remote model *draft* proposals from mining output. Even then, the proposal goes through `reviewing`, and the drafting model is a decider in the meta machine like any other.

## Privacy

All mining is local. Before any object leaves the box (shared benchmarks, bug reports), file paths and code contents are hashed, and rationales are optionally redacted. The OCEL file is the unit of sharing, and it is scrubbed deterministically.
