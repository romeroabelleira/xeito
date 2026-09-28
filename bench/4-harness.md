# Bench 4 · Harness end to end (2026-09-27)

P4: the daemon, a session, the free chat machine and delegation, driven by a client over the Unix socket, against the real tiers on the [reference workstation](../docs/architecture/09-reference-deployment.md).
Large model: qwen3.6:27b (GPU, resident); small: Qwen3.5-2B (CPU).
Reproduce:
- `mix xeito.daemon` (tier endpoints in the environment)
- [`scripts/p4_harness_live.exs`](scripts/p4_harness_live.exs) `WORKSPACE [prompt …]`

The workspace is a scratch Python project with one bug: `total(net, tax_rate)` returns `net * tax_rate`, and its unit test expects `net + net * tax_rate`.

## 1. Two turns, as the transcript shows them

| Prompt | Path | Wall-clock |
|---|---|---|
| "What files are in this project?" | Intent `question` (large) → free chat → `bash find …` (Risk `safe` by rule) → answer | 8.0 s |
| "The pricing test is failing. Fix it." | Intent `edit` → `fix_failing_test` → reproduce (`make test` fails) → Triage `code_bug` (large 0.99) → delegated chat run: read test, `ls`, read source, `edit` → verify (`make test` passes) → done | 11.0 s |

The fix is the one-line correct change. Every step is a logged state or effect: the chat run is a child of `fix_failing_test` (`…/e3/run`, `part_of`), and its tool calls are effects of that child.

The same session in the TUI (TermUI) additionally exercised:
- **Review.** `rm -rf` on a cache directory went to `ask_human`. The status line turned into a y/n prompt. `y` ran it, and `n` told the model it was denied.
- `/why` and quit/reattach. The session outlived the TUI in the daemon, and `--session` showed the earlier turns.

## 2. Latency to the first streamed token

The P4 exit target is a median of **under 1.5 s** from the prompt to the first streamed token, which includes the Intent decision. Seven short prompts, large-only Intent:

| | median | range |
|---|---|---|
| prompt → first token | **1.70 s** | 1.19–2.33 s |
| of which Intent (escalation, large) | ~0.85 s | 0.83–0.86 s |

**Not met.** The dominant cost is Ollama, not Xeito. With `tools` in the request, Ollama holds back the streamed content until it has ruled out a tool call. For "hi", measured directly:

| Ollama `/api/chat`, qwen3.6:27b warm | first chunk | total |
|---|---|---|
| without `tools` | 0.28–0.47 s | 0.56–0.74 s |
| with one tool | 1.38–1.57 s | 1.41–1.60 s |

When the model calls a tool first ("What does pricing.py do?"), the first *text* comes after the tool's round trip.

**Tried: Intent small-first** (Qwen-2B, θ = 0.6, as in bench 3). The CPU model answered 3 of 7 prompts in ~0.1–0.2 s. When it was unsure, both tiers ran and the tail grew. The median went from 1.70 s to 1.89 s, so large-only Intent is kept.

**Next options, in order of expected effect:**
1. A chat backend that streams while it parses tool calls: llama-server does. That would mean serving the large model from llama.cpp instead of Ollama, and one resident model on 24 GB rules out running both.
2. Start the chat turn while Intent is still being decided, and discard it if another machine is chosen. This costs GPU time on the queue.
3. Rules for the obvious intents (greetings, "run the tests"), before any model.

## 2b. After the Intent rules (2026-09-28)

`Intent` now has rules for small talk ("hi", "thanks") and "run the tests". Small talk is also answered without tools, so Ollama streams at once. Same seven prompts:

| | median | range |
|---|---|---|
| model warm | **1.34 s** (target < 1.5 s) | 0.85–2.81 s |
| after the keep-alive expired | 2.41 s | 1.16–3.98 s (the first reply pays ~2.5 s to reload the model) |

The target is met with the model warm, mostly thanks to small talk (hi: 1.70 → 0.85 s). Answers that begin with a tool call are unchanged at 2.4–2.8 s to the first text. The trade-off behind `XEITO_KEEP_ALIVE` is VRAM for the desktop against that reload.

Also verified live: `/skill:…` (pi-format skill), `check` (a failure delegated, fixed, checks pass: 12.5 s) and `commit` (message drafted, approved, committed: 2.4 s).

## 3. Tests

106 tests. The harness pieces are tested against a scripted, streaming Ollama stub:
- chat loop, Risk gate, review with approve/deny, invalid tools, step limit
- delegation from `fix_failing_test`
- sessions: routing, history, `/why`, resume from the log
- the socket protocol, and step mode with breakpoints and human decisions
