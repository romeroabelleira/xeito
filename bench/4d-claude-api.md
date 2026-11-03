# Bench 4d · The frontier models as deciders, on the Claude API (2026-11-02)

P4d step 3 asks which hosted model each remote tier should name, by measurement. This run covers the `remote_frontier` part: Claude Sonnet 5.5 against Claude Opus 5.5, both through `Xeito.Backends.Anthropic` ([04](../docs/architecture/04-delegation.md)), on every decision type whose policy allows an off-box tier, with the local model as the baseline. The open-weight candidates for `remote` and the decision models for `remote_decision` go through OpenRouter and are not measured here.

Reproduce:
- `mix run bench/scripts/p4d_remote_models.exs bench/decisions/p4d` with the tiers configured as for the daemon (`. ~/.config/xeito/tiers.env`), from a shell where the 1Password CLI can reach the app when the key is an `op://` reference.
- One JSON report per type in [`decisions/p4d/`](decisions/p4d/).

Setup:
- **Frontier:** `claude-opus-5-5` and `claude-sonnet-5-5`, each request with the type's JSON Schema as `output_config.format` and effort `low`, no temperature, the fallback beta on. The backend returns no probabilities, so every answer is terminal and no calibration or cascade is measured.
- **Local:** the resident 27B on the GPU, as in [bench 3b](3b-openrouter.md).
- Every example of each type, each tier called directly, outside the escalation ladder, as `mix xeito.eval` does. Risk is skipped: its policy forbids off-box tiers. The seed sets are synthetic.
- Another session's `mix ci` ran on the same machine during part of the run. The local model's median matches bench 3b (0.50 s), so no distortion is visible.

## 1. Accuracy and latency

Accuracy over all examples (coverage is 1.0 everywhere; no errors, no refusals).

| Type (n) | local 27B | Opus 5.5 | Sonnet 5.5 | p50 / p95 local | p50 / p95 Opus | p50 / p95 Sonnet |
|---|---|---|---|---|---|---|
| intent (111) | 0.991 | 1.000 | 1.000 | 502 / 513 ms | 1149 / 1768 ms | 950 / 1566 ms |
| triage (65) | 0.969 | 0.985 | 0.985 | 498 / 521 ms | 1424 / 1943 ms | 1006 / 1994 ms |
| done (45) | 1.000 | 1.000 | 1.000 | 497 / 502 ms | 1438 / 1918 ms | 983 / 2125 ms |
| refine (42) | 1.000 | 1.000 | 1.000 | 494 / 501 ms | 1327 / 1932 ms | 988 / 1437 ms |
| skill (40) | 0.975 | 1.000 | 1.000 | 546 / 563 ms | 1396 / 2008 ms | 1020 / 2119 ms |

- The two frontier models answer every type with the same accuracy, and their macro F1 differs only on triage (0.985 against 0.983). Each gains at most one example over the local model on intent and triage, and one on skill.
- The local model's confidence is calibrated (ECE 0.00–0.03, 0.00–0.04 after temperature scaling). The frontier models give none.
- The local model answers in half a second; Sonnet takes about twice that at the median and Opus about three times, with a tail near 2 s for both.

## 2. Cost

From the API's token counts at list prices (`Xeito.Backends.Anthropic.price/1`); the API reports no cost itself. Both models received the same prompts, so their token counts are equal.

| Model | Decisions | Input tokens | Output tokens | Cost | Per decision |
|---|---|---|---|---|---|
| Opus 5.5 | 303 | 135,192 | 3,574 | $0.612 | $0.0020 |
| Sonnet 5.5 | 303 | 135,192 | 3,543 | $0.306 | $0.0010 |

- No prompt was read from the cache: a decision's prompt (330–460 tokens) is below the cache's minimum, so the cost is the list price times the tokens. Bench 3b's open-weight model through OpenRouter cost $0.00003 per decision, 30–70 times less.
- The local model costs its energy only (bench 2).

## Findings

1. **For decisions, Sonnet 5.5 is the frontier model.** It decides as well as Opus 5.5 on every type, at half the price and a faster median. If the `remote_frontier` tier ever joins a type's deciders, its model is `claude-sonnet-5-5`. This says nothing about chat, which the benchmark does not measure; the reference deployment keeps Opus for chat.
2. **Decisions stay local.** The policy forbids off-box deciders for Risk and the ladder lists `local` alone for the other types; the measurement agrees: the frontier models are within 0–2.5 points of the local model, cost a thousand times more per decision, take two to three times longer, and give no confidence to cascade on.
3. **The eval assumed confidences.** `Xeito.Decision.Eval.ece/1` crashed on a decider that returns none, which the Claude backend always does; it now reports no calibration error for such a decider. The benchmark script keeps each decision's cost, which `mix xeito.eval` drops, so that a report can state spend.
