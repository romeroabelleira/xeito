# Bench 2 · Typed decisions, zero-shot (2026-09-27)

This is the P2 evaluation of the four built-in decision types against every decider on the [reference workstation](../docs/architecture/09-reference-deployment.md), followed by the [gate test](../docs/architecture/03-typed-decisions.md#the-gate-test).
Reports: [`decisions/p2/`](decisions/p2/). Reproduce with `mix xeito.eval risk triage done intent --out DIR` (tier endpoints from the environment).

## Data: read this first

The example sets in `priv/decisions/*/examples.jsonl` are **synthetic seed sets written for P2** (`"source": "synthetic"`). They are balanced per label, and intent is multilingual (en/de/es/gl).

| Type | Examples | Labels |
|---|---|---|
| intent | 103 | question 20 · edit 21 · run 17 · explain 16 · plan 15 · other 14 |
| risk | 128 | safe 40 · review 46 · forbidden 42 (the forbidden ones form the *dangerous set*) |
| triage | 65 | code_bug 20 · test_bug 15 · flaky 15 · env_problem 15 |
| done | 45 | done 15 · continue 15 · blocked 15 |

- These are below the plan's 150–200 labels per type. With 45–128 examples, an accuracy difference of a few points is noise (roughly ±7–15 points at 95% confidence).
- **The rules and the examples come from the same author.** So the `risk` rule accuracy is optimistic by construction. Only the dangerous-set property (100% blocked) is meaningful, as a regression test.
- Real labels come from dogfooding (P4 onwards). Every human override becomes a label.

## Deciders

| Decider | What it is |
|---|---|
| `rules` | the type's deterministic rules only; abstains when no rule fires |
| `baseline` | the *static rule*: rules, else the most frequent label |
| `system_one` | Laya multilingual via `laya-serve`, CPU, `/v1/systemone` |
| `small` | llama-server on the CPU, **one-token scoring**: prefill `{"value": "`, renormalise the top-50 logprobs over the options |
| `large` | `qwen3.6:27b` via Ollama on the GPU: JSON-schema `format`, logprobs at the value position |
| `pipeline` | what a run uses: rules → the type's deciders → severity floor |

Accuracy counts an abstention as wrong. ECE uses 10 bins; ECE(T) is after 2-fold temperature scaling. Latency is end to end per decision, warm.

## Results

### Zero-shot, all deciders (small = Qwen3.5-0.8B)

| Type | baseline | rules (coverage) | system_one | small 0.8B | **small 2B** | large | 
|---|---|---|---|---|---|---|
| intent | 0.21 | 0.01 (1%) | 0.74 | 0.51 | **0.86** | **0.99** |
| risk | 1.00* | 0.64 (64%) | 0.30 | 0.47 | 0.38 | 0.84 |
| triage | 0.43 | 0.14 (15%) | 0.31 | 0.60 | 0.68 | **1.00** |
| done | 0.33 | 0.11 (11%) | 0.40 | 0.53 | **0.96** | **0.98** |
| **p50 latency** | 0 | 0 | **55–67 ms** | 250–325 ms | 510–690 ms | **~470–510 ms** |

\* Circular: see Data above.

Calibration (raw ECE): the large tier is well calibrated (0.01–0.10). The small tiers are not (0.14–0.47, and still 0.08–0.23 after temperature scaling).

Per language, intent: large 0.98–1.00 in every language. Laya 0.65–0.76. Qwen-2B 0.85–0.92 in en/de/es, but **0.67 in Galician**.

### Gate

**No small candidate passes for any type.** The gate requires a candidate within 0.02 of large and at least 0.02 above the static rule. The closest is Qwen3.5-2B on `done` (0.956 vs 0.978, missing by 0.002 on 45 examples), which is inconclusive.

### Default pipeline (rules → large → floor)

| Type | accuracy | coverage | macro-F1 | ECE | p50 / p95 |
|---|---|---|---|---|---|
| intent | 0.99 | 0.99 | 0.995 | 0.005 | 501 / 505 ms |
| risk | 0.95 | 1.00 | 0.955 | 0.031 | 0 / 478 ms (rules answer 64% instantly) |
| triage | 0.97 | 0.99 | 0.977 | 0.006 | 511 / 535 ms |
| done | 0.93 | 0.96 | 0.954 | 0.014 | 474 / 479 ms |

## Findings

1. **On this hardware, the GPU-resident large model is both the most accurate and not slower than the CPU generative tier.**
   - A value-only decision from the 27B model takes ~500 ms, with near-perfect accuracy and calibration.
   - The CPU tiers are only *faster* for the encoder (Laya, ~60 ms), which is the least accurate zero-shot.
   - So the small CPU tiers earn their place only when the large model is **not loaded** (a model swap costs seconds), when the GPU is busy, or after **fine-tuning** (P7). This reorders P3: tier placement and swap awareness matter more than a fixed cascade.
2. **Laya zero-shot is unusable for safety.** It classified **34 of 42 forbidden commands as `safe`**. This confirms the design rule: `Risk` is decided by rules plus a severity floor (a model can only *raise* caution), and never by a classifier alone. Rules blocked 100% of the dangerous set.
3. **Model size matters more than architecture at the small end.** Moving from Qwen3.5-0.8B to 2B lifted intent from 0.51 to 0.86 and done from 0.53 to 0.96, at twice the latency. The default small model is now 2B.
4. **One-token scoring works.** Confidence is the renormalised probability at the first value token, read from the unconstrained distribution (bench 0). It needs no generated text and gives a full distribution in one forward pass. Where options share a first token, the scorer descends one token and renormalises again.
5. **Rules are cheap coverage, not accuracy.** They fire on 1–64% of inputs with 0.9–1.0 precision. Every rule that fires saves a model call.

## Decisions taken

- Default deciders for all four types: **rules → large** (`deciders [:large]`). The small tiers stay evaluated but do not decide until they pass the gate.
- Default small model for the CPU tier: **Qwen3.5-2B-Q8_0**.
- The large tier's per-example verdicts are exported (`--predictions large` → `decisions/p2/default/*.large.jsonl`) as distillation data for the P7 fine-tuning of Laya / the small tier.
- P2 exit (end to end): `fix_failing_test` on a seeded failing Python repo ([`scripts/e2e_fix_failing_test.exs`](scripts/e2e_fix_failing_test.exs)).
  - With the CPU tier: Qwen-2B answered `code_bug` at confidence 0.68, below the 0.8 threshold. The decision abstained, the run moved to `ask_human`, and the CPU verdict and its confidence were logged as evidence.
  - With the large tier: `code_bug` at 0.988, straight to planning.
  - Both runs finished `done` after the fix.
