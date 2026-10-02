# Xeito — Implementation plan

Status: living plan, last updated 2026-09-30 (P0–P3b done; P4 built, dogfooding; P4b in progress) · Architecture: [architecture/00-overview.md](architecture/00-overview.md) · Design: [design.md](design.md)

## Guiding rules

- **A vertical slice first.** By the end of P2, a real machine runs on the reference workstation with a real typed decision, and it is logged. Everything else deepens that slice.
- **Every phase ends in something runnable and a written exit check.** No phase starts before the previous one's exit criteria are met, with the exception of work marked *parallel*.
- **Dogfood from P4.** Xeito's own development tasks become its first machines.
- **Rough sizing** assumes one developer working part-time, about 10–15 h/week. The durations are calendar weeks at that pace.

## Milestones

The original schedule assumed part-time pace from 2026-10-05. P0–P3 were built with agent assistance and finished well ahead of it, so the remaining phases are re-based on the actual dates. Their durations are unchanged. P4's exit needs two weeks of dogfooding, so it cannot close before 2026-10-12.

| Phase | Scope | Planned (original) | Effective / re-based | Evidence |
|---|---|---|---|---|
| P0 · Toolchain and repository | Elixir/OTP toolchain, CI, docs, guard hooks | 2026-10-05 → 10-19 | done 2026-09-27 | [bench 0](../bench/0-baseline.md), CI green |
| Bench 1 · contention (inserted) | CPU and GPU tiers under load | — | done 2026-09-27 | [bench 1](../bench/1-contention.md) |
| P1 · State-machine core and log | statecharts on `gen_statem`, effects as data, OCEL SQLite log, recovery | 2026-10-19 → 11-16 | done 2026-09-27 | 34 tests, property test |
| P2 · Typed decisions | decision types, rules, the CPU model, calibration, eval sets | 2026-11-16 → 12-14 | done 2026-09-27 | [bench 2](../bench/2-decisions.md) |
| P3 · Delegation tiers | escalation as a machine, the GPU tier, policy, budgets | 2026-12-14 → 2027-01-04 | done 2026-09-27 | [bench 3](../bench/3-escalation.md) |
| P3b · OpenRouter tier (inserted) | hosted open models as an off-box tier | — | done 2026-09-27 | [bench 3b](../bench/3b-openrouter.md) |
| P4 · TUI harness | daemon, TUI, chat and structured machines, step mode, skills, compact log, dogfood fixes | 2027-01-04 → 02-08 | built 2026-09-27 → 09-28; dogfooding until ≥ 2026-10-12 | [bench 4](../bench/4-harness.md) |
| P4b · Context economy (inserted) | shape tool output before the model reads it, elide old tool output from the conversation; measured with the code-navigation benchmark | — | ≈ 2026-09-30 → 10-12, within P4's dogfooding | [bench 4 §4](../bench/4-harness.md#4-code-navigation-outline-symbol-reads-and-the-project-map-2026-09-28) |
| P5 · OCEL export and process mining | OCEL validation, PM4Py sidecar, proposals (including token sinks), **promotion candidates** (frequent free-chat requests), **data portability** (decisions as training data, pi sessions, OTLP/CLEF, XES/PNML) | 2027-02-08 → 03-08 | ≈ 2026-10-12 → 11-09 | — |
| P6 · Web inspector | timeline, machine view, step debugger, decision relabelling (Hologram or LiveView) | 2027-03-08 → 04-12 | ≈ 2026-11-09 → 12-14 | — |
| P7 · Meta machine | mining-driven proposals, **promotion of skills and machines** (draft, benchmark, review, release, retire), counterfactual replay, graduating decisions, threshold tuning, **rollback-netcode ideas** (snapshots, prompt fingerprints, speculative decisions) | 2027-04-12 → 05-10 | ≈ 2026-12-14 → 2027-01-11 | — |
| P8 · Packaging and v0.1 | Burrito binary, install script or setup machine, guides, benchmark write-up | 2027-05-10 → 05-31 | ≈ 2027-01-11 → 02-01 | — |
| P9 · Bridges (added) | MCP server and client, ACP agent, `pi-xeito`, surveying and bridging other harnesses | — | after P4, alongside P5 (≈ 2 weeks) | — |

The original dates of P5–P8 follow the original chain of durations. The re-based dates assume part-time pace, and P9 runs alongside P5 rather than after P8, since it needs only the daemon's socket.

```mermaid
gantt
  dateFormat YYYY-MM-DD
  axisFormat %b %y
  section Foundation
  P0 Toolchain & repo            :done, p0, 2026-09-27, 1d
  P1 State-machine core + log    :done, p1, 2026-09-27, 1d
  section Decisions
  P2 Typed decisions + CPU model :done, p2, 2026-09-27, 1d
  P3 Delegation tiers            :done, p3, 2026-09-27, 1d
  P3b OpenRouter tier            :done, p3b, 2026-09-27, 1d
  section Harness
  P4 build                       :done, p4b, 2026-09-27, 2d
  P4 dogfooding                  :active, p4d, 2026-09-28, 2w
  P4b Context economy            :p4b, 2026-09-30, 12d
  section Insight
  P5 OCEL, mining, portability   :p5, after p4d, 4w
  P6 Web inspector               :p6, after p5, 5w
  P7 Meta machine loop           :p7, after p6, 4w
  section Release
  P8 Packaging & v0.1            :p8, after p7, 3w
  section Reach
  P9 Bridges (pi, others)        :p9, after p4d, 2w
```

---

## P0 · Toolchain and repository (≈2 weeks)

1. On the reference workstation, install Erlang/OTP 29.1 and Elixir 1.20.4 via **mise** (or asdf). Pin the versions in `.tool-versions` ([08](architecture/08-tech-stack.md#versions-to-pin-in-p0)).
2. Create the umbrella-less Mix project `xeito` with these top-level namespaces: `Xeito.Machine`, `Xeito.Run`, `Xeito.Decision`, `Xeito.Effects`, `Xeito.Log`, `Xeito.Tiers`.
3. Set up CI (GitHub Actions or Forgejo): `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer` (or the built-in type checker), and `mix test`. Since 2026-10-01 the formatter includes Styler, and `.credo.exs` disables the Credo checks Styler already rewrites ([08](architecture/08-tech-stack.md#code-style)).
4. Build **llama.cpp**: a CPU build with AVX-512 (the small tier), plus Vulkan and HIP/ROCm builds for benchmarking against Ollama only.
   Run `llama-server` as a systemd *user* unit on `127.0.0.1:8081` ([09](architecture/09-reference-deployment.md#services)).
5. Run upstream **`laya-serve`** (laya-multilingual) as a pinned Docker container on `127.0.0.1:8082` with an API key file, and measure its CPU latency.
6. Download 2–3 small GGUF models, the candidates from [09](architecture/09-reference-deployment.md#tier-small-cpu). Record the SHA256 of each file in `models.lock`.
7. Write `LICENSE` (Apache-2.0 recommended), `CONTRIBUTING.md` and a code of conduct.

**Status:** done 2026-09-27 (planned 2026-10-19). CI is green on GitHub; only the optional ROCm benchmark is pending. See [bench 0](../bench/0-baseline.md).

**Exit:** `mix test` is green in CI. `curl localhost:8081/completion` returns grammar-constrained JSON from a CPU model on the reference workstation. `llama-bench` numbers for each candidate are recorded in `bench/0-baseline.md`.

## P1 · State-machine core and event log (≈4 weeks)

1. Build the `Xeito.Machine` DSL, which compiles to a `%Machine{}` struct: states (hierarchical), events, guards, timeouts and finals ([02](architecture/02-state-machine-core.md)).
2. Add compile-time checks: every state reaches a final state, and every non-final state has a timeout. Verifying that decision values label transitions is stubbed until P2.
3. Implement the generic `Xeito.Run` (`gen_statem`, `handle_event_function`) that interprets a `%Machine{}`, plus `Xeito.RunSupervisor`.
4. Implement the effect runner with three tools, `read`, `write` and `bash`, and a fake runner for tests.
5. Implement `Xeito.Log`: an append-only writer to SQLite (via `exqlite`) using the OCEL 2.0 relational layout, with the event types from [05](architecture/05-event-log-and-process-mining.md#event-types).
6. Rebuild a run's state from the log after a crash (event sourcing).
7. Add exporters: Mermaid and SCXML from `%Machine{}`.
8. Write the first two machines, driven by code only with no model: `run_tests` and `fix_failing_test` (with a stubbed triage).

**Status:** done 2026-09-27 (planned 2026-11-16).
- The DSL compiles to validated data, and a pure engine is shared by `Xeito.Run` and `Xeito.Run.Recovery`.
- `Xeito.Log` writes OCEL 2.0 in SQLite. PM4Py reads it natively (`read_ocel2_sqlite`).
- Local, fake and `:none` effect runners exist; `mix xeito.export` produces Mermaid and SCXML.
- 34 tests pass, including a property test (up to 1,000 runs), kill/restart and in-flight-effect recovery.

**Exit:** a property test shows that, for random event sequences, the log alone reproduces the final state. Killing a run mid-way and restarting it resumes in the same state. The Mermaid export of `fix_failing_test` matches [02](architecture/02-state-machine-core.md).

## P2 · Typed decisions and the CPU model (≈4 weeks)

1. Build the `Xeito.Decision` DSL: inputs, closed output type, rules, deciders and thresholds ([03](architecture/03-typed-decisions.md)).
2. Build the schema compiler: output type → JSON Schema → a backend-specific constraint (llama.cpp `json_schema`/GBNF, Ollama `format`, Anthropic tool schema).
3. Implement two small-tier clients:
   - `Xeito.Tiers.SystemOne`, which calls `/v1/systemone` (`laya-serve` now; any Jev-compatible backend later). It always pins `"model": "multilingual"`.
   - `Xeito.Tiers.Small` (`Req` → llama-server), which returns the value plus **token log-probabilities** for the enum alternatives.
   Decision types compile to `Choice`/`Score`/`Noul` requests for the first client ([03](architecture/03-typed-decisions.md#system-one-models-an-external-ecosystem-to-plug-into-sept-2026)).
4. Compute confidence: logprob-based as the primary source, self-consistency with k=3 as a fallback. Record both.
5. Make abstention a value, and complete the compile-time check that decision values match transitions.
6. Build the first decision types: `Intent`, `Triage`, `Risk`, `Done?`. Hand-label **150–200** examples each, covering every language the deployment actually sees, into `priv/decisions/*/examples.jsonl`. Seed the examples from real `mix test` failures and from shell history.
7. Add the eval task `mix xeito.eval <Decision>` for accuracy, macro-F1, ECE and latency p50/p95 per model.
8. Run the **three-way gate test** (rule vs calibrated small candidate vs local large model, cost-weighted, with a pre-declared margin). Pick the default small decider per decision type, and delete the losers ([03](architecture/03-typed-decisions.md#the-gate-test)).
9. Log the large model's verdicts as training data for the local fine-tuning of laya-multilingual in P7.

**Status:** done 2026-09-27 (planned 2026-12-14), with an honest negative result. See [bench 2](../bench/2-decisions.md).
- Decision DSL, one-token logprob scoring, three tier clients, the decider ladder, `mix xeito.eval` and the gate are built.
- The seed sets are synthetic (45–128 per type).
- No small tier passed the zero-shot gate, so defaults are rules → large. The GPU-resident 27B model decides at ~500 ms with 0.93–0.99 accuracy.
- **Consequence for P3:** swap- and placement-aware routing (Q16) matters more than a fixed small→large cascade.

**Exit:** `fix_failing_test` runs end-to-end on a seeded failing repo, with `Triage` decided by the CPU model and logged with its confidence. The eval report for all four decision types is committed. `Risk` rules block the dangerous-command test set 100% of the time.

## P3 · Delegation tiers (≈3 weeks)

1. Implement the escalation machine ([04](architecture/04-delegation.md)), itself a `%Machine{}` running as a child run.
2. Add tier clients. `Large` uses the Ollama API on `:11434` with `format` = JSON Schema, detects which model is loaded (`/api/ps`), and models the swap substate. `Remote` uses ReqLLM (Anthropic) with tool-use schemas. `Human` asks through the TUI or a CLI prompt.
3. Add the policy DSL and guards for data locality, budgets and a maximum number of swaps.
4. Implement cost accounting per decision and per run: tokens, currency, wall-clock and estimated energy.
5. Batching: queue large-tier decisions per model so that swaps are avoided. Batch System One questions per state into one request, and give each backend a queue with its measured capacity ([bench 1](../bench/1-contention.md)).

**Status:** done 2026-09-27 (planned 2027-01-04). See [bench 3](../bench/3-escalation.md).
- The escalation machine runs as a logged child run, with swaps as states.
- Policy: remote off by default, local-only data never leaves the box, and Risk can never go remote (tested). Per-run budgets for spend and swaps; per-backend queues.
- Remote tier (stub-tested; no credentials on the reference box).
- Cost and estimated energy per decision and per run. Held-out threshold tuning.
- Exit measured: Qwen-2B takes 78% / 53% / 37% of done / intent / triage decisions at unchanged accuracy. `done` meets the <30% large-share target; intent and triage don't yet.

**Exit:** on the eval sets, the cascade (rules → small → large) matches or beats large-only accuracy while calling `large` for fewer than 30% of decisions (target to be confirmed in P2). The remote tier is provably never called for `Risk` (test). The swap state appears in the logs.

## P3b · OpenRouter tier (inserted, ≈1 week)

Inserted after P3. P2 showed that the small tiers need a stronger, calibrated tier behind them, and the local GPU holds one large model at a time. OpenRouter offers hosted open-weight models *with logprobs*, which the remote Claude tier cannot provide.

**Research (2026-09-27): what OpenRouter can and cannot replace.**

| Needed from the remote tier | Direct Anthropic | OpenRouter → Claude | OpenRouter → open-weight |
|---|---|---|---|
| JSON-schema output | yes | yes (require the parameter) | yes, per provider endpoint |
| Logprobs, i.e. calibrated confidence | no | no | yes, on selected endpoints |
| Effort / thinking off | yes | yes | where supported |
| Server-side refusal fallback | yes (beta) | no (only error-based model fallback) | same |
| Cost in the response | tokens only | `usage.cost` (USD) | `usage.cost` (USD) |
| No training / no retention | org terms | `zdr` routes Claude away from Anthropic's endpoints | `data_collection: "deny"`, `zdr: true` |
| Free health check | — | `GET /api/v1/key` | `GET /api/v1/key` |

**Decision:** keep Claude on the direct Anthropic tier, and add OpenRouter as a separate tier for open-weight models with logprobs.

1. `Xeito.Tiers.OpenRouter`: chat completions with the decision's JSON Schema (`strict`), temperature 0, reasoning off, `logprobs`. Every request sets `provider.require_parameters`, `data_collection: "deny"` and `zdr` (default on); providers can be pinned.
2. Confidence from `top_logprobs` at the value, shared with the local large tier. Endpoints without logprobs yield a terminal result. Refusals are errors. Cost from `usage.cost`; provenance names the serving provider.
3. Policy: `openrouter` and `remote` are *off-box tiers* under one gate (`remote:`), one locality rule and one spend budget. `Risk` never reaches either; `mix xeito.eval` skips them for types that forbid them.
4. An `openrouter` state in the escalation machine (v1.1.0), so the path is logged and mined like any other tier.
5. Configuration from the environment (`XEITO_OPENROUTER_KEY_FILE`, `_MODEL`, `_PROVIDERS`, `_ZDR`). A free key check (`key_info/1`).
6. Evaluation: `mix xeito.eval --deciders small,large,openrouter` reports `small→openrouter` next to `small→large`.

**Status:** done 2026-09-27. See [bench 3b](../bench/3b-openrouter.md).
- Hosted Qwen3.6-35B-A3B: 0.91–0.97 accuracy against 0.98–1.00 for the local 27B, ~0.45 s median, about $0.00003 per decision. Calibration is worse and does not improve with temperature scaling; pin a provider before fitting thresholds.
- Live: with public inputs and the large model unloaded, the ladder small → openrouter committed in 1.2–1.4 s without a swap, and the spend was charged to the run. Local-only inputs and Risk never reached it.

**Exit:** on the eval sets, the OpenRouter tier's accuracy and calibration are measured next to the local large model, with cost per decision. Off-box gating is tested for both off-box tiers. At least one live escalation reaches the `openrouter` state and is logged with its cost.

## P4 · TUI harness at pi parity (≈5 weeks)

1. Build a minimal terminal UI: an input box, a streaming transcript, a status line (machine / state / tier / cost) and a diff view.
   Use TermUI by default and spike ExRatatui if needed. The TUI is a separate Burrito binary talking to `xeitod` ([07](architecture/07-harness-frontend.md#processes-and-clients), [08](architecture/08-tech-stack.md#the-tui-the-weakest-link)).
2. Provide a **free chat machine**, the escape hatch: `idle → thinking → tool_use → idle`, with the large model deciding `ToolChoice`. This gives rough pi parity for unstructured use, and the machine is still logged.
3. Build machine selection from `Intent` (e.g. "the tests fail" → `fix_failing_test`).
4. Add step mode and breakpoints in the TUI ([06](architecture/06-observability.md#2-step)).
5. Support project context files (`AGENTS.md`), and read pi's skills directory format where feasible.
6. Add session save/resume, which comes for free from the log.
7. ~~Write the optional `pi-xeito` bridge extension~~, moved to [P9](#p9--bridges-to-other-harnesses-after-p4-2-weeks) on 2026-09-28.
8. **Dogfood.** Use Xeito for its own development for at least two weeks, and log the friction as issues.

**Status:** in progress since 2026-09-27. See [bench 4](../bench/4-harness.md).
- Done (items 1–6):
  - `xeitod` (`mix xeito.daemon`) with a JSONL client API on a private Unix socket.
  - The TUI (`mix xeito.tui`, TermUI) with transcript, edit diffs, status line (machine, state, tier, cost), reviews and step mode, plus a line-mode client (`mix xeito.chat`).
  - The free chat machine (tools as effects, `bash` behind `Risk`, reviews), machine selection from `Intent`, and delegation (`fix_failing_test` hands the fix to a chat child run).
  - Step mode and breakpoints, with human decisions logged as labels.
  - Per-workspace logs, and sessions that survive the client and are rebuilt from the log after a daemon restart.
  - A systemd user unit that puts the desktop first (`deploy/systemd/xeitod.service.example`): about 100 MB of RAM and no CPU when idle.
  - Idle sessions close after 2 h and resume transparently from the log. Budget entries are removed with their run or session, and a periodic sweep catches the rest.
  - [USAGE.md](../USAGE.md): setup, everyday examples, step mode, the log, evaluation, extending.
  - Skills in pi's format (Agent Skills, `SKILL.md`), read from the project's `.pi/skills` and `.agents/skills`, then `~/.pi/agent/skills` and `~/.agents/skills`. They are listed for the model, loaded on demand through a `skill` tool confined to the skill's directory, and can be forced with `/skill:name`.
  - Structured machines: `run_tests`, `fix_failing_test`, `commit` (drafted message, human approval, fixed git commands) and `check` (the project's checks, with failures delegated to a chat run). With the free chat machine, that makes five.
  - `/machines` (summary, routing, per-project usage) and a toggleable TUI status bar: GPU, VRAM, power and temperatures, resident models and unload countdown, CPU and RAM, git branch/dirty, session usage, the determinism budget, spend, the off-box budget left, and queues. The daemon polls only while a client shows the bar. Segments are configurable (`/statusbar show|hide`) and saved as a client preference.
  - Lifecycle: session status in the log is truthful (`open`, `closed`, `interrupted`), idle workspace logs close and reopen transparently, and `mix xeito.log sessions|prune` gives explicit, whole-session retention (a dry run unless `--apply`).
  - Compact log (2026-09-28): chat messages are stored once as hash-linked chains of plain JSON rows, results are not repeated, terms are compressed, and replay checks each requested effect against the log (desync detection). A 40-call chat run's payload drops from 1.4 MB to 49 KB, and growth is linear instead of quadratic. `mix xeito.log stats|verify|compact`. See [05](architecture/05-event-log-and-process-mining.md#storing-inputs-not-state).
  - From dogfooding (2026-09-28):
    - A blinking prompt cursor. It is solid while typing and stops blinking after 10 s idle, so an idle TUI doesn't wake up.
    - `write`/`edit` refuse `deps/`, `_build/`, `node_modules/`, `.git/` and `.xeito/`. In the dogfood session, an edit to a dependency looked done but never took.
    - A quote-aware Risk tokenizer that treats read-only pipelines as safe. It decides 33 of that session's 35 commands by rule, where 13 were decided by rule before.
    - A project map in each chat turn's instructions (`Xeito.Source.RepoMap`): the project kind, top-level directories, modules with files (plus docs and public functions if they fit in 6,000 characters), and dependencies.
    - From a dogfood session (2026-10-01; chat machine 0.6.0):
      - Turns that stop at the step limit close with a tool-less summary turn.
      - "go ahead" and similar after an unfinished turn continue it, by rule and with tools. Tools are dropped only for small talk the rule detects, not whenever the model says `other`.
      - Exact repeat calls are not run again, and a model repeating its opening sentence gets a nudge.
      - Two steps in a row of failing calls end the turn, and an empty answer is noted.
      - `xargs` before a read-only command is read-only.
    - `read` gains `outline` (modules and functions with line ranges) and `symbol` (one definition by name) for Elixir files, and `write`/`edit` report a file that no longer parses in the same step (`Xeito.Source`, using Elixir's own parser). Other languages can follow through tree-sitter.
    - The chat machine (0.2.0) runs a quick check before answering a turn that edited files, and gives the model up to two tries to fix a failure. The check asks whether the code still builds (format and warnings for Mix, `cargo check`, `go build`, `tsc`), which takes about 0.5 s on this project. A `check.quick` alias or `check-quick` target overrides it.
  - Latency: `Intent` rules decide small talk and "run the tests" without a model, and small talk gets no tools, so its answer streams at once.
- Live: "the pricing test is failing, fix it" goes from Intent to a verified fix in 11 s.
- Live (2026-09-28): `/skill:py-inventory`, "run the checks and fix what fails" (a delegated fix, then the checks pass) and "commit these changes" (drafted, approved, committed) all work end to end.
- Exit latency: the median time to first token is **1.34 s** with the model warm (1.70 s before the Intent rules). Answers that start with a tool call still take 2.4–2.8 s, because Ollama holds back text while tools are offered. After the keep-alive has expired, the first reply adds ~2.5 s for the model reload. See [bench 4](../bench/4-harness.md).
- Open: dogfooding (item 8), which also measures the "five structured machines in daily use" criterion.
- Deviation from [07](architecture/07-harness-frontend.md): the TUI uses the same JSONL socket as every other client, not Erlang distribution.

**Exit:** a two-week dogfood log with ≥ 50 runs. At least five structured machines are in daily use. Median latency of `Intent` + first token is under 1.5 s on the reference workstation.

## P4b · Context economy (inserted, ≈1.5 weeks)

Added 2026-09-30, from the code-navigation benchmark ([bench 4 §4](../bench/4-harness.md#4-code-navigation-outline-symbol-reads-and-the-project-map-2026-09-28)). A chat run read about 500k input tokens and wrote about 3k: every step resends the whole conversation, including every earlier tool output. As in caveman's proxy, the gain is in what the model *reads*, not in how it writes. P4b runs during P4's dogfooding window, so dogfooding benefits as soon as it lands.

1. **Shape tool output before the model reads it** (`Xeito.Tools.Shape`, pure and deterministic):
   - Shell output: strip terminal escape codes, collapse repeated or near-identical lines (`… 37 similar lines`), keep the first and last lines.
   - Test and compile output (ExUnit, `mix compile` and similar, recognised by shape): keep failures, errors, warnings and the summary.
   - `grep`/`rg`: group matches by file, capped per file and in total. `find`/`ls`: capped.
   - Very large `read`s: return the outline and the first part, pointing to `symbol` or a line range.
   - Originals stay retrievable. Every result is already in the log, so shaped text ends with `[full output: read result "e12"]`, and `read` gains a `result` option.
   - The shaper is versioned. A replay then reproduces exactly what the model saw, and the desync check keeps working. This covers part of P7's prompt-build fingerprint.
2. **Elide old tool output from the conversation:**
   - Tool outputs older than the last few steps become one-line stubs, e.g. `[elided: output of grep -rn … (212 lines); re-run or read result "e7"]`.
   - The system prompt, the user's request, the model's own messages and the latest check output stay whole.
   - Stubs are applied in batches, every K steps. Changing an earlier message breaks the model's prompt cache from that point, and batching keeps that rare (the same slack as the history window's 80 → 60 trim).
   - A session's history applies the same stubs to earlier turns, which matters most for long multi-turn sessions.
3. **Measure** with the code-navigation benchmark (`bench/scripts/p4_code_nav.exs`), as variant D against C:
   - input tokens per run;
   - the step of the first edit;
   - runs that finish within the step limit and pass the quick check;
   - how often the model reads back an elided result. A high rate means the elision is too aggressive.

**Status:**
- Item 1 done 2026-09-30 (`Xeito.Tools.Shape`, applied in the effect runner, so the shaped text is logged next to the full output).
  - `read` gains `lines` and `result`.
  - On the tool outputs of the logged dogfood session, reads shrink by 59% (171k → 70k characters, mostly whole files of a dependency's source). Shell output shrinks by 10% (39k → 36k), because the model already pipes through `head`.
- Item 2 done 2026-09-30 (chat machine 0.3.0).
  - Tool outputs over 400 characters, except the last 4 and skill instructions, become stubs in batches of 6. Each stub names the call and its full effect id.
  - Only what is sent to the model is elided: the run's context and the session history keep everything.
  - The chat client sends Ollama only its own message fields.
- Item 3 done 2026-09-30, see [bench 4 §5](../bench/4-harness.md#5-p4b-tool-output-shaping-and-elision-benchmark-d-2026-09-30).
  - Input tokens per run fell by 62% (606k → 230k), and wall time roughly halved. The token half of the exit criterion is met.
  - The other half fails: no run with shaping reached an applied edit, against 3 of 3 without it. Shaped reads made the model page through files one step at a time.
4. **Follow-ups from benchmark D** (added 2026-09-30):
   - Shape reads by purpose rather than size: keep the project's own files whole up to a larger limit, and shape dependency sources and generated files.
   - Answer a missed edit with the nearest matching region and its line numbers.
   - Add a task-specific acceptance check to the benchmark, since compiling is a weak measure of success.
   - Then rerun benchmark D.
   - Status 2026-09-30: reads shaped by purpose and the nearest match on a missed edit are done (`0e0fddc`, [bench 4 §6](../bench/4-harness.md#6-p4b-follow-ups-benchmark-d-rerun-2026-09-30)).
     - Tokens −63%; runs with an applied edit 2 of 3 (0 of 3 before), against 3 of 3 without P4b.
     - Next: elision keeps the latest read of each project file whole, since the model re-read the stubbed file in slices. Then the benchmark's acceptance check and another rerun.
   - Status 2026-10-01: elision keeps the latest whole read of each of the last three project files read (chat machine 0.4.0, [bench 4 §7](../bench/4-harness.md#7-keeping-project-reads-whole-benchmark-d-rerun-2026-10-01)).
     - Tokens −47% against the project-map baseline; runs with an applied edit 3 of 3 (baseline 2 of 3); one run finished.
     - Remaining: the benchmark task is ambiguous ("prompt cursor": both finished runs blinked the `> ` marker), so the acceptance check comes with a reworded task. P4b exits once that check shows no loss of success with the savings.
   - Status 2026-10-01: the task is reworded and has a behavioural acceptance check ([bench 4 §8](../bench/4-harness.md#8-an-unambiguous-task-and-an-acceptance-check-benchmark-d-rerun-2026-10-01)).
     - Neither variant passes it within 25 steps (0 of 3 each), so "no loss of success" holds only trivially.
     - Tokens −44%; runs reaching an edit 2 of 3 against 1 of 3.
     - Both edited P4b runs stopped with code that does not compile. To make success measurable: the fix budget past the step limit, then dependency APIs in the map, or a larger step limit for the benchmark.
   - Status 2026-10-01: the fix budget is done (chat machine 0.5.0). A failing quick check gets up to two fixes, also at the step limit, with 4 model turns past `max_steps` shared between them.

Not in P4b (see [bench 4 §4](../bench/4-harness.md#4-code-navigation-outline-symbol-reads-and-the-project-map-2026-09-28)): a fix budget beyond the step limit, and dependency APIs in the project map. Both address task success rather than tokens and are separate harness fixes.

**Exit:** on the benchmark, input tokens per run are at least halved compared with variant C, with no fewer runs reaching an edit. Shaping and elision are covered by tests, including replay: a recovered run reproduces the shaped and elided messages exactly.

## P5 · OCEL export and process mining (≈4 weeks)

1. Validate the SQLite layout against the OCEL 2.0 spec, and add JSON export.
2. Build a Python sidecar (`tools/mining/`, managed by `uv`) using PM4Py: object-centric discovery, flattening, DFG, Inductive Miner, and alignments against the machines' Petri-net exports.
3. Build the Elixir side: native DFG and variants for the live views, and `mix xeito.mine` to run the sidecar and ingest its findings as structured records.
4. Implement the proposal generators from the table in [05](architecture/05-event-log-and-process-mining.md#kinds-of-proposal). Start with rule-based ones only. One of them ranks **token sinks**: which tools, commands and files fill the model's context most, from the logged results, with a suggested fix for each (added 2026-09-30, after caveman's `learn`).
5. Publish an anonymised sample log. This is useful for research partners and for grant evidence.
6. **Data portability** (added 2026-09-28): a single `mix xeito.export` that turns what Xeito learns into files other systems can use. Exports are local files you pull, and nothing is pushed by default.
   - **Redaction levels:** *structure* (no text, paths hashed; also what item 5 needs), *metadata*, and *full*. Off-box rules apply as for the tiers: data marked local-only never goes to an opt-in sink.
   - **Decisions as training data**, probably the most valuable export for other systems. Logged decisions with input, value, confidence, tier, cost and latency go out as JSONL (the `examples.jsonl` shape), a chat-style fine-tuning format, and Parquet/Hugging Face datasets. Human overrides from step mode are labels, and a human replacing a model decision is a preference pair (chosen vs rejected) for DPO-style training.
   - **Conversations:** pi session JSONL, whose entries point to their parent just like the log's message chains, so pi can resume a Xeito conversation. Also OpenAI-style message lists with tool calls, and Markdown transcripts. The message table is already plain JSON (2026-09-28), so SQLite tools, DuckDB and Datasette can read conversations without an export.
   - **Traces:** OTLP following OpenTelemetry's GenAI conventions (runs as traces, effects and decisions as spans, message text only when opted in), for Langfuse, Arize Phoenix, Jaeger or Grafana Tempo. CLEF (JSON Lines for Seq and `jq`) as the lighter option. A GELF sink only as an explicit opt-in, since it sends data off the machine. Deferred from the P4 compact log, 2026-09-28.
   - **Process mining:** OCEL 2.0 JSON/XML (item 1), flattened XES per object type for ProM, Disco, Apromore and Celonis, and the machines as PNML Petri nets for conformance checking in other tools.
   - **Machines:** SCXML (already exported) plus XState JSON. Importing SCXML is the other half: statecharts designed elsewhere could run as Xeito machines.
   - **Decision types:** a bundle of the output schema (already JSON Schema), the eval set and the calibrated thresholds, so another harness can reuse a decision type, for example through the P9 `xeito_decide` tool.
   - **Metrics:** cost, tokens, latency, estimated energy and the determinism budget per run as CSV/Parquet, and live OpenMetrics for Prometheus from the daemon's monitor.
   - **Standard envelopes and hashes** (added 2026-09-30):
     - Events in the daemon's stream and in exports use the [CloudEvents](https://cloudevents.io/) envelope (`id`, `source`, `type`, `time`, `subject`, `data`).
     - Exported hashes use [RFC 8785](https://www.rfc-editor.org/rfc/rfc8785) (JSON Canonicalization Scheme) with SHA-256, so any language can verify them: decision inputs, message chains, replay checks. The log's own ids stay as they are.
     - Optionally, new ids become time-ordered [RFC 9562](https://www.rfc-editor.org/rfc/rfc9562) UUIDv7.
   - **Provenance:** a [W3C PROV](https://www.w3.org/TR/prov-overview/) export (entities, activities, agents) that answers which run, decision, model or human produced a change. It is useful for audits, and PROV is a standard model that other tools read.
7. **Promotion candidates** (added 2026-10-02; the first half of [promotion](architecture/05-event-log-and-process-mining.md#promotion-from-free-chat-to-skills-and-machines)): trace signatures for free-chat runs, prompt clusters, variants per cluster, and `mix xeito.candidates`, a report of the frequent requests with their dominant variant, success, cost and a rule-based `PromotionTarget`. No drafting yet: the report is reviewed by hand, and the first skills and machines are written from it.

**Exit:** a weekly mining report generated from the dogfood logs, with ≥ 3 actionable proposals. PM4Py loads `.xeito/log.sqlite` without conversion. A dogfood session exports to pi's session format and resumes in pi, and logged decisions export as a dataset that trains a classifier outside Xeito.

## P6 · Web inspector (≈5 weeks)

1. **Spike (1 week):** build the machine view in **Hologram** and, as a fallback, in **Phoenix LiveView**. Pick one using the criteria in [08](architecture/08-tech-stack.md#decision-procedure).
2. Build the views in the order given in [06](architecture/06-observability.md#views-web-inspector): timeline → machine view → step debugger → decision table → mining dashboard.
3. Relabelling a decision in the UI writes to the eval set, closing the labelling loop.
4. Bind the inspector to `127.0.0.1` only. Remote access goes through an SSH tunnel or a private VPN.

**Exit:** a run started in the TUI can be watched, paused, stepped and replayed from the browser. A decision can be relabelled and shows up in the next `mix xeito.eval`.

## P7 · Meta machine: mining-driven improvement (≈4 weeks)

1. Implement the meta machine itself as a Xeito machine ([05](architecture/05-event-log-and-process-mining.md#the-meta-state-machine)).
2. Add counterfactual replay (`re-decide`, `re-machine`) as the benchmarking gate.
3. Add graduation of decision types: fine-tune and calibrate laya-multilingual locally on the logged verdicts (the "stuntd" pattern), then graduate to a classifier (Bumblebee embedding + logistic head) and on to a rule ([03](architecture/03-typed-decisions.md)).
4. Let the large or remote model draft proposals from the mining output. A human reviews every proposal.
5. Automate threshold tuning (θs, θl) per decision type ([04](architecture/04-delegation.md#tuning-thresholds-from-the-log)).
6. Extend replay with further ideas from rollback netcode (deferred from the P4 compact log, 2026-09-28; see [05](architecture/05-event-log-and-process-mining.md#storing-inputs-not-state)):
   - **Snapshots:** checkpoint a run's context every N events, so counterfactual replay and long recoveries start from a checkpoint instead of from the beginning. Snapshots are a disposable cache; the logged inputs remain the source of truth.
   - **A prompt-build fingerprint:** log a hash of the tool specs and prompt templates with each chat call, so a replay can tell "the machine is unchanged, but the prompt code changed" apart from a real desync.
   - **Speculative decisions:** let a cheap tier predict the next decision, start acting on it, and reconcile when the confirmed decision arrives, as rollback does with predicted inputs. Only confirmed decisions are logged. This is for latency, and needs read-only effects or effects that can be undone.
7. Implement **promotion** as a Xeito machine ([05](architecture/05-event-log-and-process-mining.md#promotion-from-free-chat-to-skills-and-machines)), on top of the P5 candidates: `PromotionTarget` with a model behind the rules, drafting of skills and machines, benchmarking by replaying the cluster's requests, human review, release, monitoring and retirement. Exit addition: at least one skill and one machine promoted from the dogfood log, each beating its baseline.

**Exit:** at least one decision type has graduated to a classifier with equal or better F1. At least one machine revision was proposed by mining, accepted and benchmarked. The determinism budget of the dogfood machines has measurably increased since P4.

## P8 · Packaging, docs and v0.1 (≈3 weeks)

1. Package as a single-binary CLI (Burrito) plus `mix release` for the server mode.
2. Write an install script for Linux, with an Ubuntu-based recipe, llama.cpp setup and model download. Candidate: a `setup` **machine** for the guided part (detect the tiers, test each endpoint, write the environment file), since it has real states and checks.
3. Write documentation: a machine-authoring guide, a decision-authoring guide, and the benchmark protocol.
4. Write up the reference benchmark ([09](architecture/09-reference-deployment.md#benchmark-protocol)) as a blog post, with a talk proposal.
5. Tag v0.1.0.

**Exit:** a fresh Ubuntu-based machine goes from install to the first `fix_failing_test` run in under 15 minutes.

## P9 · Bridges to other harnesses (after P4; ≈2 weeks)

Added on 2026-09-28: bridges wait until the harness itself has been dogfooded.

1. **Standard protocols first** (added 2026-09-30), so one implementation reaches many harnesses:
   - An [MCP](https://modelcontextprotocol.io/) **server**: Xeito's machines and typed decisions become tools for Claude Code, pi, Cursor and other MCP clients. `xeito_decide` is one of them.
   - An MCP **client**: tools of configured MCP servers become effects, logged and gated by Risk and policy like `bash`.
   - An [ACP](https://agentclientprotocol.com/) (Agent Client Protocol) **agent**: editors that speak ACP, such as Zed, can drive `xeitod` directly. The TUI becomes one client among several.
   - API errors take the [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) Problem Details shape, so bridges handle them uniformly.
2. **`pi-xeito`**, the original P4.7 ([07](architecture/07-harness-frontend.md#pi-bridge-optional)): a small pi extension that registers `/xeito <machine>` and an `xeito_decide` tool, talking to the daemon's JSON Lines socket. It would be the only TypeScript in the project.
3. **Survey other agent harnesses** worth bridging, for example Odysseus AI and Jensen (to be researched; neither is evaluated yet). For each, note its extension or RPC surface, and whether its loop can call out to typed decisions or delegate to a machine.
4. Build the bridges the survey justifies. Each is a thin client of `Xeito.Api`, not a new code path in the daemon.

**Exit:** at least one bridge drives a Xeito machine end to end from the other harness, and the run is logged like any other. The MCP server passes the protocol's own conformance checks (its inspector tool), and a decision is requested from another agent through it.

---

## Cross-cutting tracks (parallel)

| Track | When | What |
|---|---|---|
| Eval data | P2 → | Keep growing the labelled decisions. Every human override is a label. |
| Benchmarks | P0 → | Nightly `bench/` run on the reference workstation: hardware, models, decisions, machines. |
| Writing | P1 → | One short post per phase. It feeds the grant narratives and talks. Includes a mapping of Xeito's record-keeping and human oversight (the log, reviews, step mode, human decisions) to the EU AI Act (articles 12 and 14) and ISO/IEC 42001, for public-sector users. |
| Change risk | P4 → | Added 2026-10-01: a CRAP gate (max 30) on every test run, the pre-commit hook and CI. 16 older functions started in `test/crap_baseline.exs`, mostly untested TUI, API and rendering dispatch. Worked down to empty the same day, test-first (unit tests for the TUI, renderer, API connection, session commands, deciders' evaluation and log tasks; large dispatch functions split). The baseline stays as the mechanism, empty. Mutation testing (`mix xeito.mutate`) added the same day, starting with Risk: its first run left 49 of 140 mutants alive (among them, nothing pinned that a newline separates commands, without which a command after a safe one would pass as safe, nor the secret-file exclusions); after the new tests, none. Policy, Budget and the chat machine's guards followed (first runs: 67%, 44% and 35% killed; now all 100%, and one equivalent mutant was dead code in Policy, removed). |
| Conformance | P5 → | Execution semantics against [W3C SCXML](https://www.w3.org/TR/scxml/) (added 2026-09-30). Xeito exports SCXML; its engine should also behave like SCXML where their features overlap: event processing, entry and exit order, eventless transitions, and history and parallel states if the engine supports them. Translate the applicable tests of the W3C SCXML test suite into machines and run them in CI. Most tests assume an ECMAScript data model, so only a subset applies. Document every deviation in [02](architecture/02-state-machine-core.md). |

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Hologram is too immature for the inspector | The P6 spike includes a LiveView fallback. Both are JS-free for us. |
| Small CPU models are not accurate enough | The cascade covers the gap. Measure in P2 before building P3 on assumptions. |
| ROCm instability on consumer AMD GPUs | Keep a llama.cpp Vulkan build as a fallback. |
| Machines feel rigid for exploratory work | The free chat machine (P4.2) is always available, and it is still logged and mined. |
| Scope creep toward a "platform" | Rule 6 in [01](architecture/01-principles.md): new behaviour is a machine, not a feature. |
