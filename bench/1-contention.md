# Bench 1 · CPU decisions vs. GPU generation (2026-09-27)

**Question.** Is the CPU a good place for typed-decision models while a large model generates on the GPU at the same time?
**Answer on the reference workstation: yes.** Neither side slows the other down by more than ~10%. The real limit is how each decision server handles *concurrency*, not contention with the GPU.

Script: [`scripts/bench1_contention.py`](scripts/bench1_contention.py) (standard-library Python; endpoints from the environment). Hardware and software are as in [bench 0](0-baseline.md). Raw JSON is kept privately.

## Setup

- **Large model:** `qwen3.6:27b` (Q4_K_M) in Ollama with an 81,920-token context. It is **fully resident in VRAM** (19.3 GB, 100% GPU per `/api/ps`), so it has no CPU layers.
  The load generator keeps it busy with back-to-back 256-token generations.
- **Deciders** (both on the CPU, both using 6 threads):
  - `laya`: `laya-serve`, multilingual checkpoint, one 4-option `choice` question.
  - `llama`: `llama-server`, Qwen3.5-0.8B-Q8_0, value-only JSON-schema enum, 4 server slots.
- **Cells:** GPU idle vs. GPU busy × concurrency 1 vs. 4. Each worker sends 30 requests (120 per cell at c=4).
- CPU utilisation is the whole machine (16 hardware threads), sampled from `/proc/stat`.

## Results

| GPU | Decider | Concurrency | p50 ms | p95 ms | Decisions/s | CPU busy | Large model tok/s |
|---|---|---|---|---|---|---|---|
| idle | laya | 1 | 64.3 | 64.6 | 15.7 | 38% | — |
| idle | laya | 4 | 255.6 | 257.2 | 15.7 | 38% | — |
| idle | llama | 1 | 328.5 | 340.3 | 3.0 | 34% | — |
| idle | llama | 4 | 725.5 | 744.1 | 5.4 | 28% | — |
| **busy** | laya | 1 | 62.3 | 64.7 | 16.0 | 72% | 33.4 |
| **busy** | laya | 4 | 245.2 | 273.4 | 16.1 | 71% | 33.2 |
| **busy** | llama | 1 | 348.7 | 362.4 | 2.9 | 66% | 32.2 |
| **busy** | llama | 4 | 788.9 | 808.3 | 5.1 | 60% | 32.8 |

The large model alone generated **33.4 tok/s** at 34% CPU busy.

Answers were identical in every cell (Laya `flaky`, Qwen3.5-0.8B `test_bug`; both wrong, see bench 0), so contention did not change the decisions.

## Findings

1. **Contention is negligible in both directions.**
   - Laya's latency is unchanged under GPU load (62 vs. 64 ms p50).
   - llama-server is 6–9% slower (349 vs. 329 ms at c=1).
   - The large model loses at most 3.6% of its throughput (32.2 vs. 33.4 tok/s) while the CPU deciders run.
   The supposition holds, **provided the large model is fully in VRAM**. If its context or size forces CPU offload, the picture changes; rerun this bench after any such change.
2. **The GPU tier is not free for the CPU.** Ollama's GPU generation alone keeps ~34% of the machine busy, about 5 of 16 hardware threads, with host-side sampling and synchronisation. The deciders' 6 threads each still fit, and the busiest cell peaked at 72%. That leaves little room for a *second* 6-thread CPU decider. Budget threads explicitly: large-tier host threads + small tiers + BEAM ≤ physical cores.
3. **Laya serialises requests.** At concurrency 4, throughput stays at ~16 decisions/s and latency rises 4× (256 ms). Requests queue behind a single inference worker.
   Consequences for Xeito:
   - put several questions for the same state into **one** `/v1/systemone` request (the contract supports multiple questions) instead of sending them concurrently;
   - treat ~16 single-question decisions/s as the tier's capacity per server;
   - have the decision runner queue with backpressure.
4. **llama-server parallel slots help, sublinearly.** 4 slots raise throughput from 3.0 to 5.4 decisions/s (1.8×), with p50 at ~730–790 ms. For bursts of generative decisions, fewer, batched requests beat high concurrency.

## Implications (reflected in the architecture)

- CPU for decision models while the GPU runs the large model: **confirmed**, with a thread budget ([09](../docs/architecture/09-reference-deployment.md)).
- The decision runner batches questions per state, and it queues per backend with that backend's measured capacity. Concurrency limits are per backend configuration, not global.
- Q16 (dynamic tier placement) stays open. Moving the small generative tier to the GPU is only attractive while the large model is *not* loaded, since the CPU placement costs the large model almost nothing.
