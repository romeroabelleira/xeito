# Bench 3b · OpenRouter tier (2026-09-27)

P3b adds `Xeito.Tiers.OpenRouter`: hosted open-weight models with logprobs, gated like the remote tier ([04](../docs/architecture/04-delegation.md#openrouter)). Measured from the [reference workstation](../docs/architecture/09-reference-deployment.md) against the local tiers of [bench 3](3-escalation.md).
Reproduce:
- `mix xeito.eval intent triage done risk --deciders rules,small,large,openrouter --out DIR --predictions openrouter`
- [`scripts/p3b_openrouter_live.exs`](scripts/p3b_openrouter_live.exs)

Setup:
- **OpenRouter:** `qwen/qwen3.6-35b-a3b` (MoE, 3B active), every request with `require_parameters`, `data_collection: "deny"` and `zdr: true`, no provider pinned. OpenRouter routed across several providers (AkashML, Parasail and Phala seen in the provenance).
- **Local:** small = Qwen3.5-2B (CPU, one-token scoring); large = qwen3.6:27b (GPU, resident).
- Seed sets are small and synthetic, which is also why sending them off-box is acceptable. Risk is not sent: the eval skips off-box tiers for types whose policy forbids them.

## 1. Accuracy, calibration and latency

| Type (n) | Large (local 27B) | OpenRouter (35B-A3B) | ECE large | ECE OpenRouter | p50 / p95 OpenRouter | p50 large |
|---|---|---|---|---|---|---|
| intent (103) | 0.990 | 0.961 | 0.012 | 0.035 | 420 / 851 ms | 500 ms |
| triage (65) | 1.000 | 0.969 | 0.026 | 0.065 | 464 / 1057 ms | 507 ms |
| done (45) | 0.978 | 0.911 | 0.028 | 0.086 | 443 / 925 ms | 474 ms |

- **Not a replacement for the resident local model.** The hosted 35B-A3B is 2–7 points less accurate and less well calibrated than the local dense 27B on every type. Temperature scaling does not fix its calibration (ECE after scaling 0.04–0.16), possibly because the requests were spread over providers whose logprobs differ (quantisation, serving stack) rather than because of one global over- or under-confidence. At least one provider returned only the chosen token's probability. Not yet verified per provider. **Pin a provider** (`XEITO_OPENROUTER_PROVIDERS`) before relying on its thresholds.
- **Latency is comparable** to a warm local model at the median (~0.45 s), with a longer tail (~1 s p95), and needs no swap.
- **Cost:** $0.0062 for 213 decisions, about **$0.00003 per decision** (~$0.03 per thousand). Energy on this machine: none beyond the waiting CPU; the provider's energy is not observable.

## 2. Cascade with a hosted second stage (held out, ε = 0.01)

| Type | small→large accuracy · small share | small→openrouter accuracy · small share |
|---|---|---|
| intent | 0.990 · 53% | 0.971 · 60% |
| triage | 1.000 · 37% | 0.939 · 48% |
| done | 0.978 · 78% | 0.978 · 91% |

The small model keeps more decisions in front of a weaker second stage, as expected. Against OpenRouter the `done` cascade even exceeds the hosted model alone (0.978 vs 0.911).

## 3. Live escalation (logged)

From `scripts/p3b_openrouter_live.exs`, with the ladder small → openrouter → large. Paths are read back from the OCEL log.

| Case | Policy | Path | Decision | Wall-clock | Spend |
|---|---|---|---|---|---|
| triage, clear bug | default (local-only) | rules → small → large → check_loaded → infer → committed | code_bug by large (0.988) | 1.29 s | $0 |
| triage, ambiguous | default (local-only) | … → large → infer → **abstained** | abstain | 1.06 s | $0 |
| triage, clear bug | public, off-box allowed, large **unloaded** | rules → small → **openrouter** → committed | code_bug by openrouter (0.996) | 1.18 s | $0.000025 |
| triage, ambiguous | public, off-box allowed, large **unloaded** | rules → small → **openrouter** → committed | code_bug by openrouter (0.915) | 1.44 s | $0.000032 |
| risk, unknown command | public, off-box allowed | rules → small → committed | review by small (0.76) | 0.55 s | $0 |

- With local-only inputs (the default) the `openrouter` state never appears: `Xeito.Policy` removes it from the plan.
- With public inputs and the large model unloaded, the hosted tier **spared a ~2.5 s swap** (bench 3) at ~1.2–1.4 s and a few thousandths of a cent, and the spend was charged to the requesting run's budget.
- **Quality caveat, as with placement awareness:** on the ambiguous triage input the local large model abstains, while the hosted model commits `code_bug` at 0.915. A tier that is less accurate but confident is not a free substitute; per-tier thresholds must be fitted per provider.
- Risk never left the machine, although the request asked for off-box tiers.

## Findings

1. OpenRouter is **not** a way to reach Claude with better properties than the direct API: no logprobs, no server-side refusal fallback, and zero-retention routing moves Claude off Anthropic's own endpoints (see the plan, P3b research).
2. It **is** a cheap, calibrated-in-principle off-box tier for open-weight models: useful when the local GPU is busy or holds another model, for public data only, and for trying larger models before downloading them.
3. Calibration depends on the serving provider. Next: pin one provider, fit θ for `openrouter` per type, and try the local large model's own checkpoint (`qwen/qwen3.6-27b`, offered with logprobs by one provider at the time of writing) to separate model from serving effects.
