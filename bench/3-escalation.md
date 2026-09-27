# Bench 3 · Escalation machine, cascade and placement (2026-09-27)

This is P3: delegation as a logged state machine (`Xeito.Machines.Escalation`), per-backend queues, policy, budgets and cost accounting. It is measured on the [reference workstation](../docs/architecture/09-reference-deployment.md).
Reproduce:
- `mix xeito.eval risk triage done intent --deciders system_one,small,large --epsilon 0.01 --out DIR`
- [`scripts/p3_escalation_live.exs`](scripts/p3_escalation_live.exs)

## 1. Selective-prediction cascade (held out)

Each small tier answers when its confidence is at least θ; otherwise the large tier decides.
- **θ** is the lowest threshold that keeps cascade accuracy within **ε = 0.01** of large-only.
- It is fitted on one half of the examples and measured on the other (2-fold). The accuracy and share are therefore held out, not in-sample.

Small tier: Qwen3.5-2B (CPU, one-token scoring). System One: Laya multilingual (CPU). Large: qwen3.6:27b (GPU).

| Type | Large-only | Cascade small→large | **Share decided without the large model** | Cascade Laya→large | Laya share |
|---|---|---|---|---|---|
| done | 0.978 | 0.978 | **78%** | 0.956 | 16% |
| intent | 0.990 | 0.990 | **53%** | 0.990 | 34% |
| triage | 1.000 | 1.000 | **37%** | 0.923 | 11% |
| risk | 0.844 | 0.836 | 5% | 0.844 | 0% |

- **The P2 gate was the wrong question for small tiers.** Zero-shot, no small tier *replaces* the large one. As a *first pass* with a tuned threshold, though, Qwen-2B takes 37–78% of decisions for three of the four types, **at unchanged held-out accuracy**. The P3 exit target was fewer than 30% of decisions reaching the large tier, at no accuracy loss. `done` meets it (22%). `intent` (47%) and `triage` (63%) reduce large calls substantially without meeting it.
- **Laya adds a cheap first step for intent** (34% at ~60 ms). For triage and done, its confident answers are wrong often enough to cost accuracy, so it is not used there.
- **Risk stays with rules plus the large model.** The small tiers' confidence is uninformative for safety (bench 2).
- The fold thresholds differ between types (θ ≈ 0.5–0.7 for done/intent/triage). That's why the tuned **threshold is per decision type** and belongs in the type's policy, fitted from logged data.
- The seed sets are small and synthetic (45–128 examples), so the shares carry wide intervals. Retune from real logs (P5/P7).

## 2. Live escalation paths (real tiers, logged)

From `scripts/p3_escalation_live.exs`. Every path below is read back from the OCEL log of the escalation child run.

| Case | Large model | Policy | Path | Decision | Wall-clock | Energy (est.) |
|---|---|---|---|---|---|---|
| triage, clear bug | unloaded | strict | rules → small (0.50) → large → check_loaded → **swapping** → infer → committed | code_bug by large (0.988) | 3.65 s | ~200 J |
| triage, clear bug | loaded | — | rules → small → large → check_loaded → infer → committed | code_bug by large (0.988) | 1.10 s | ~190 J |
| triage, ambiguous | loaded | — | … → infer → **abstained** (large below threshold) | abstain | 1.05 s | ~187 J |
| triage, ambiguous | unloaded | **placement-aware** (≥ 0.6) | rules → small (0.789) → large → check_loaded → committed | test_bug **by small** | **0.55 s** | **~36 J** |
| intent, "run the tests" | any | — | rules → small (0.909) → committed | run by small | **0.05 s** (warm cache) · 0.67 s cold | ~3 J |

- **A model swap is a state with a price:** ~2.5 s on this box (the model loads from page cache), about 3.3× the latency of a warm decision. It is budgeted per run (`max_swaps_per_run`, default 3), and the budget test shows the large tier being skipped once the budget is used up.
- **Placement awareness (Q16)** turns the unloaded-model case from a 3.6 s, 200 J swap into a 0.55 s, 36 J small-tier answer. **This is a quality trade-off, not a free lunch.** On that same input, the large model abstained when it was asked, so the small tier's `test_bug` is a guess the large tier would not have endorsed. That's why `unloaded_accept` is a policy knob (default 0.6) and not a constant.
- **Warm prompt prefixes matter on the CPU tier:** 0.67 s cold vs. 0.05 s for the same decision type once llama-server has cached the static preamble (`cache_prompt`).
- **Energy is an estimate** (configured watts × latency), not a measurement. The ratios are meaningful, the absolute joules are not.

## 3. What P3 added

| Piece | Where | Tested by |
|---|---|---|
| Escalation machine as a child run (`part_of` its parent), with tier states, `check_loaded` / `swapping` / `infer` and a `human` state | `Xeito.Machines.Escalation`, `Xeito.Escalation` | `escalation_test.exs` (paths read from the log) |
| Policy: remote forbidden by default, `:local_only` inputs never leave the box, a type-level `remote: :forbidden` (Risk) cannot be overridden, per-run budgets | `Xeito.Policy`, `Xeito.Budget` | `policy_test.exs`, the escalation tests (**remote never called for Risk or local-only inputs**) |
| Remote tier: Anthropic Messages API, `claude-opus-5`, structured output, `fallbacks: "default"`, refusal handling, priced usage | `Xeito.Tiers.Remote` | `tiers_test.exs` (stubbed; no credentials on the reference box) |
| Per-backend capacity queues (bench 1: laya-serve serialises) | `Xeito.Tiers.Queue` | `policy_test.exs` |
| Cost per decision (tokens, USD, estimated joules) in `decision_made`, and per run (`Xeito.Run.cost/2`) | `Xeito.Tiers`, `Xeito.Run` | the escalation tests |
| Held-out threshold tuning for the cascade | `Xeito.Decision.Eval.cascade/3`, `mix xeito.eval --epsilon` | `eval_test.exs` |

Not built in P3:
- Batching several System One questions into one request needs machines that ask several decisions per state. Deferred until a machine does.
- The tuned per-type thresholds are reported, not yet written back into the types. That write-back is the meta machine's job (P7).
