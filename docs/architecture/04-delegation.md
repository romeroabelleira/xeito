# 04 · Delegation as a state machine

[← Overview](00-overview.md) · Uses: [03](03-typed-decisions.md) · Deployed in: [09](09-reference-deployment.md)

## Yes: delegation *is* a state machine

"Ask the small model; if it's unsure, ask the big one; if that fails, ask the cloud or a human" is usually implemented as nested `try`/`if` blocks, and it disappears from view.
Seen through Xeito's lens, it is a machine with explicit states (who holds the decision), events (answer, abstain, timeout, verification result), guards (confidence thresholds, budgets, policy) and costs (latency, energy, money, data leaving the box).
Modelling it as a machine makes it **traceable** (which tier decided what), **tunable** (thresholds are data mined from logs) and **governable** (policy guards can forbid a tier for a decision type).

This is the model cascade / LLM-routing idea (FrugalGPT, RouteLLM) turned into a first-class, logged process.

## The escalation machine

One instance runs per decision request, as a child of the run ([02](02-state-machine-core.md#composition)).

```mermaid
stateDiagram-v2
  [*] --> rules
  rules --> committed: rule fired
  rules --> local_decision: no rule
  local_decision --> verify: decided ∧ conf ≥ θ
  local_decision --> local: abstain ∨ conf < θ
  local --> verify: decided ∧ conf ≥ θ
  local --> remote: abstain ∨ conf < θ  [policy allows remote ∧ budget]
  local --> human: abstain  [remote forbidden]
  remote --> verify: decided ∧ conf ≥ θ
  remote --> remote_frontier: abstain ∨ conf < θ
  remote_frontier --> verify: decided
  remote_frontier --> human: abstain ∨ error
  verify --> committed: guard ok
  verify --> escalate_next: guard failed
  escalate_next --> human: otherwise
  human --> committed: answered
  human --> abstained: timeout
  committed --> [*]
  abstained --> [*]
```

The diagram leaves out `remote_decision`, which sits between `local_decision` and `local` and behaves like `remote`.

A **tier** is a place on this ladder, named by the kind of model and where it runs (P4d). The API it speaks is its **backend** (`Xeito.Backends`: `system_one`, `ollama`, `openrouter`), named in the tier's configuration; each tier has a default.

| State | Kind | Default backend | Default timeout |
|---|---|---|---|
| `rules` | deterministic decision-table rules ([03](03-typed-decisions.md)) | — | 5 s |
| `local_decision` | a System One decision model on this machine: an encoder that scores the options (Laya via `laya-serve`; [03](03-typed-decisions.md#three-families-of-small-decider)) | `system_one` | 10 s |
| `remote_decision` | a hosted System One decision model (Jev); off-box | `system_one` | 30 s |
| `local` | the local GPU language model, also the chat model (may involve a *model swap*, see below) | `ollama` | 120 s |
| `remote` | a hosted language model with logprobs, so a calibrated confidence ([below](#openrouter)); off-box | `openrouter` | 90 s |
| `remote_frontier` | the strongest hosted language model; no logprobs, so its answer is terminal; off-box | `openrouter` | 180 s |
| `human` | ask in the TUI; the run waits | — | configurable |
| `verify` | the guard on the decision's output (file exists, command parses, …) | — | 1 s |

Each decision type lists the tiers it uses, in order (`deciders`); all built-in types use `[:local]`. Policy and configuration drop tiers from that list: an unconfigured tier is never reached, and remote tiers are opt-in.

**Names before P4d.** Logs written before escalation machine 2.0.0 name the tiers as they were: `system_one` is now `local_decision`, `large` is `local`, `openrouter` is `remote`, and `remote` (then the direct Anthropic API) is `remote_frontier`. The small language model tier (`small`, llama-server) was removed: no small model passed the P2 gate. Readers of older logs, such as P5's mining, map the old names to the new ones.

### As implemented (P3, renamed in P4d)

`Xeito.Machines.Escalation` implements this as a regular machine: one child run per decision, logged in the same OCEL log with a `part_of` relation to the requesting run.
- **Routing.** The transitions live on the parent `deciding` state. Every tier's result bubbles up to one set of guarded transitions: commit, move to the next tier in the plan, or abstain.
- **The plan.** Rules first, then the permitted and configured tiers, then optionally a human. It is computed by `Xeito.Policy` before the run starts.
- **The frontier tier** asks for no logprobs, so models without them (Claude) can serve it; its result is terminal when policy admits it.
- **Measured** in [bench 3](../../bench/3-escalation.md) (with the names before P4d).

### OpenRouter

`Xeito.Backends.OpenRouter` (P3b) serves both hosted language model tiers through OpenRouter's OpenAI-compatible chat completions, with the decision's JSON Schema as `response_format`. For `remote` it asks for `logprobs`/`top_logprobs`, and the confidence is computed exactly like the local tier's, so it takes part in thresholds and cascades. For `remote_frontier` it does not, and the answer is terminal.
- **Routing restrictions in every request.** `provider.require_parameters: true` (only endpoints that honour every requested parameter: the schema, and logprobs when asked), `data_collection: "deny"`, and `zdr: true` (zero data retention) by default. Providers can be pinned. Both filters rest on OpenRouter's knowledge of provider policies; they narrow the exposure, they do not make the tier local.
- **One gate for every remote tier.** `Xeito.Policy` treats every `remote*` tier as *off-box*: one `remote:` switch, the same locality rule (`:local_only` never leaves), the same per-run spend budget. `Risk` never reaches them, and `mix xeito.eval` skips them for types that forbid them.
- **No direct Anthropic tier (since P4d).** Claude is reached through OpenRouter as `remote_frontier`. That gives up Anthropic's server-side refusal fallback: a refusal is an error, and the decision moves on or abstains. Under `zdr: true`, Claude requests are routed away from Anthropic's own endpoints to cloud endpoints where structured output is not uniformly supported, which the choice of the frontier model has to check.
- **Measured** in [bench 3b](../../bench/3b-openrouter.md) (with the names before P4d).

**Placement awareness (Q16, decided).** In `check_loaded`, if the local model is not resident and an earlier tier's answer has confidence ≥ `policy.unloaded_accept` (default 0.6), that answer is committed instead of paying for a swap. Measured: 0.55 s and ~36 J instead of 3.6 s and ~200 J. The price is accepting an answer the local model might not have endorsed.

## Guards on escalation

Escalation is guarded by **policy**, which is data and never a prompt:

```elixir
policy Xeito.Decisions.Risk,      remote: :forbidden          # never send commands to an API
policy Xeito.Decisions.PlanShape, remote: :allowed, max_usd_per_run: 0.50
policy :default, remote: :ask_first, max_large_swaps_per_run: 3
```

- **Data-locality guard: by source, not by classifier.** Inputs carry a provenance tag set when they are read: the workspace path, the tool, the skill. Examples: anything from mail, ticketing or wiki integrations, or from configured private paths, is `:local_only`.
  Such a decision cannot enter an off-box tier (`openrouter`, `remote`). Tiny classifiers are **not** used to judge "may this leave the box": independent tests found PII catch rates of ~16–23% for Laya and Kev ([references §7](references.md#7-system-one-decision-models-jev-and-open-clones)). Regex and NER scans only add defence in depth on top of the source tags.
- **Hosted decision APIs are `remote`.** A hosted System One model (Jev) is a remote tier like any other. It is allowed for synthetic, public or private-project data, and **never for `:local_only` data**. For public bodies, sending data to a cloud AI provider typically counts as processing on behalf under data-protection law, and a US provider is additionally subject to the CLOUD Act (see [10](10-security-and-sandboxing.md#data-protection)).
- **Budget guard.** A run carries a budget (money, wall-clock, GPU swaps). Once it is exhausted, escalation goes to `human`.
- **Idempotency.** A decision escalates at most once per tier. There are no loops. This is enforced by the machine's structure, not by counters.

## The cost of a tier change is a state

On the reference workstation, only one large model fits in ~24 GB of VRAM at a time (Ollama with one loaded model).
Switching from `qwen3.6:27b` to `gemma4:31b` is a **model swap** that costs seconds.
So `large` has substates:

```mermaid
stateDiagram-v2
  state large {
    [*] --> check_loaded
    check_loaded --> infer: wanted model loaded
    check_loaded --> swapping: other model loaded
    swapping --> infer: loaded
    infer --> [*]
  }
```

`swapping` is logged like any other state. The swap cost therefore shows up in process mining, and the scheduler can batch local-tier decisions by model ("decide all pending `PlanShape` before swapping").

## Delegation of *work*, not only of decisions

The same machine shape covers handing a whole **sub-task** to a stronger agent. Examples: "have the remote model write this migration", or delegating to an external coding agent such as pi or Claude Code running headless.
The sub-task is an invoked child machine whose deciders are all one tier. It returns an artefact, and the parent verifies it with guards. The delegate sees only the context the parent explicitly passes. That context is logged, so it is auditable what left the box.

## Queues

Decision queues are **in-memory, per backend**: a process per decider backend with the capacity measured in [bench 1](../../bench/1-contention.md). They need no database.
Durability comes from the event log. A decision request is an effect (`effect_requested`), and one without a logged result is re-dispatched when a run recovers (at-least-once delivery, implemented in P1 for all effects).
A persistent job queue (Oban on PostgreSQL or SQLite) would duplicate the log and add a second source of truth.

## What gets recorded

Each escalation writes one event per state entered, including `from_tier`, `to_tier`, `reason` (`:low_confidence | :abstain | :guard_failed | :timeout | :policy`), the confidence that triggered it, and the cost incurred.
That is exactly what [05](05-event-log-and-process-mining.md) needs to answer:

- How often does `local_decision` escalate for each decision type? → candidates for more examples or fine-tuning.
- How often does `local` *agree* with the `local_decision` answer it overrode? → that threshold is too strict.
- How often does `verify` reject a remote tier? → the remote prompt or context is poor.
- What does each type cost end-to-end? → a per-decision-type **cost-of-certainty** curve.

## Tuning thresholds from the log

P3 implements the held-out version of this: `Xeito.Decision.Eval.cascade/3` picks the lowest θ that keeps cascade accuracy within ε of large-only. On the P2 seed sets, Qwen-2B then decides 78% (done), 53% (intent) and 37% (triage) of cases without the large model, at unchanged accuracy ([bench 3](../../bench/3-escalation.md)). Writing tuned thresholds back into the types is P7.


The thresholds θs and θl are not constants. For each decision type, the tuner reads logged pairs (small's answer and confidence, the eventual committed answer) and picks θ to minimise:

```
E[cost] = P(escalate | θ) · cost(next tier) + P(wrong ∧ not escalated | θ) · cost(error)
```

The tuner reads `cost(error)` from each decision type's declaration: a wrong `Risk` decision is expensive, a wrong `FileRelevance` decision is cheap.
A threshold change is proposed as a machine update, and a human reviews it, like any other change coming from mining ([05](05-event-log-and-process-mining.md#the-meta-state-machine)).
