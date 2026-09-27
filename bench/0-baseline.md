# Bench 0 · P0 baseline (2026-09-27)

This is the first measurement on the [reference workstation](../docs/architecture/09-reference-deployment.md). Hardware is given by class only: an 8-core desktop CPU with AVX-512 (Zen 4 class), ~64 GB RAM, and a consumer AMD GPU with ~24 GB VRAM.
Raw `llama-bench` JSON is kept with the operator's private configuration, because it embeds exact device names.

## Software

| Component | Version |
|---|---|
| llama.cpp (CPU, source build, `GGML_NATIVE=ON`) | v0.5.0 (`7fe450e`) |
| llama.cpp (Vulkan, official prebuilt) | b11207 |
| Laya (upstream `laya-serve`, CPU container, torch 2.14 CPU) | v0.3.20 |
| Models | see [`models.lock`](../models.lock) (all Q8_0) |

## 1. llama-bench, CPU only

`-p 512 -n 128 -r 3`, tokens per second (mean ± sd).

| Model | Threads | Prompt (pp512) | Generation (tg128) |
|---|---|---|---|
| gemma-3-270m-it | 6 | 2753 ± 125 | 181.0 ± 4.9 |
| gemma-3-270m-it | 8 | 2435 ± 16 | 178.0 ± 5.1 |
| Qwen3.5-0.8B | 6 | 553 ± 1 | 62.4 ± 0.1 |
| Qwen3.5-0.8B | 8 | 697 ± 0 | 62.0 ± 0.2 |
| granite-4.0-1b | 6 | 292 ± 11 | 33.0 ± 0.3 |
| granite-4.0-1b | 8 | 388 ± 3 | 33.6 ± 0.0 |
| Qwen3.5-2B | 6 | 273 ± 1 | 28.0 ± 0.0 |
| Qwen3.5-2B | 8 | 344 ± 4 | 27.1 ± 0.0 |

Prompt processing scales with threads (+25–33% from 6 to 8). Generation is memory-bound and flat.

## 2. llama-bench, GPU (Vulkan), all layers offloaded

| Model | Prompt (pp512) | Generation (tg128) | vs CPU (8 threads) |
|---|---|---|---|
| Qwen3.5-0.8B | 19521 ± 1196 | 374.2 ± 5.1 | 28× pp · 6× tg |
| Qwen3.5-2B | 12202 ± 221 | 250.4 ± 0.5 | 35× pp · 9× tg |

The ROCm/HIP comparison is **pending**. The prebuilt HIP backend loads, but it finds no device, because the user running it lacks access to the ROCm compute device node (a host permission issue, not a llama.cpp one).

## 3. Typed-decision latency (end to end, HTTP, warm)

| Decider | Request | Latency | Notes |
|---|---|---|---|
| llama-server CPU, Qwen3.5-0.8B, 6 threads | JSON-schema enum **with** a free-text rationale | ~1.47–1.64 s | 75 output tokens; generation dominates |
| llama-server CPU, Qwen3.5-0.8B, 6 threads | JSON-schema enum **only** | **~345 ms** (p50 of 5) | Meets the <400 ms p50 target |
| Laya multilingual (mmBERT-base), CPU container, 6 threads | `/v1/systemone` choice, 4 options | **62–73 ms** | All option probabilities returned |
| Laya multilingual | `/v1/systemone` choice + score + noul, German input | **86–89 ms** | |
| Laya, first request after start | — | ~23 s | Checkpoint build. Preload or warm up at start |

## Findings that change the design

1. **Rationale is expensive.** A 200-character rationale costs ~4× the latency of the decision itself on the CPU tier. Decisions should put the value first, make the rationale optional (off for the small tier by default), and cap it hard when it is requested ([03](../docs/architecture/03-typed-decisions.md)).
2. **llama-server logprobs are pre-grammar.** The reported `top_logprobs` come from the unconstrained distribution: the top alternatives at the enum position were tokens the grammar forbids. Confidence for grammar-constrained decisions must be computed by renormalising over the tokens the grammar allows, or by scoring each option explicitly. The raw top-k cannot be used as-is.
3. **Laya's router ignores the server-side model preference.** With `LAYA_MODELS=multilingual`, an English input was still routed to (and triggered a build of) the English checkpoint. Every request must pin `"model": "multilingual"`. Xeito's System One client will always send it.
4. **Zero-shot quality is not there yet, as predicted.** On a code-triage example whose answer is `code_bug`, Qwen3.5-0.8B answered `test_bug` and Laya answered `flaky` (p=0.70). This is the reason the gate test and graduation path exist ([03](../docs/architecture/03-typed-decisions.md#the-gate-test)). Laya's German customer-support answers were confident and plausible, which matches its training domain.
5. **The GPU is 6–9× faster for small-model generation.** When the large model is *not* loaded, running the small generative tier on the GPU is attractive. Tier placement could itself be a state (GPU idle vs. busy) rather than static configuration. Recorded as an [open question](../docs/architecture/11-open-questions.md).

## P0 exit criteria

| Criterion | Status |
|---|---|
| `mix test` green in CI | ✅ GitHub Actions: format, warnings-as-errors, credo, tests, dialyzer |
| `curl localhost:8081/completion` returns grammar-constrained JSON from a CPU model | ✅ (via `/v1/chat/completions` with `response_format: json_schema`) |
| `llama-bench` numbers for each candidate recorded | ✅ CPU for all four candidates, Vulkan for the Qwen models. ROCm pending |
