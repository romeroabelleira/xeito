# Weekly freshness check of the implementation plan

The [plan](implementation-plan.md) cites outside facts with a date: model names and prices, hosted endpoints, library versions, other projects' features, protocol revisions, Ollama's behaviour, and preconditions that items wait on. This is the checklist that keeps those dates honest. Run it once a week, in under an hour; it reads and compares, it never measures. Findings go on the plan item itself, in the plan's own convention: `(checked YYYY-MM-DD: …)`. An item whose facts still hold is left untouched.

Each section names the plan lines by phase and item, what the plan claims, and the exact way to check it. "Holds" means the source still says what the plan says.

## 0. The plan against the repository: `mix xeito.plan.check`

Run `mix xeito.plan.check` first; it measures, the rest of this checklist reads. It checks the plan against the repository and prints a finding per plan line, by check:

1. **Modules.** A `Xeito.Some.Module`, `Mix.Tasks.Xeito.X` or `mix xeito.x` the plan names with no `defmodule` under `lib/` or `test/`. A line that says the name is planned, removed, renamed, not adopted, or was, is left alone, so a stale name is fixed by saying what became of it.
2. **Links.** An anchor that slugs no heading of the plan (GitHub's rules), or a relative link that reaches no file, or no heading of that file.
3. **Stale.** A `(checked YYYY-MM-DD` note older than 14 days (the last note on a line counts), and a "next", "pending", "planned" or "waits for" item whose nearest date, on its line or else the last one above, is older than 60 days.
4. **Milestones.** A milestone row that says done for a section whose status line does not say so and whose last step is not marked done; a section whose steps are all marked done, or whose status line says done, for a row that does not.

It exits 1 with any finding, so CI runs it nightly as a step that reports without failing the job (`.github/workflows/ci.yml`); it is not part of `mix ci`. A stale name or a dead link is fixed on the spot. A stale note is what the sections below re-check: dated anew when the facts still hold, otherwise corrected on the plan line. A finding that is a judgement (a step named before it is built, a milestone row the author wants to read differently) stays in the report until the plan says so in words.

## 1. Claude models and prices

**Plan lines.** P3b research table (direct Anthropic column: schema output, no logprobs, refusal fallback in beta); P4d tier table and step 3 (Sonnet 5.5 and Opus 5.5 as deciders, Sonnet at half the price); P4d step 4 (Sonnet 5.5's endpoints take no `temperature`; cache reads at a tenth of the input price); P4d step 5 (`output_config.format`, `fallbacks: "default"`, the price table "to keep with the models", `claude-opus-5-5` as the reference frontier model); P4j step 3 (Haiku 5.5 costs five times as much past 100k tokens).

**In the code.** `lib/xeito/backends/anthropic.ex`: `@version` (the `anthropic-version` header), `@fallback_beta` (the `anthropic-beta` header for `fallbacks: "default"`), `@prices` (per model: input, output and cache-read price per million tokens, window, longest answer), `@tiers` (price tiers by prompt length) and `@fallbacks` (the models that take `fallbacks: "default"`).

**How to check.**
1. Open the pricing page, `https://platform.claude.com/docs/en/about-claude/pricing`. For every row of `@prices`, compare base input, output and "cache hits" per million tokens, and the long-context section (which models pay more past a prompt length, and from which length) against `@tiers`. Every model named in `@fallbacks` must have a row in `@prices`, or its calls are costed at zero.
2. Open the models overview, `https://platform.claude.com/docs/en/about-claude/models/overview`: the current model ids, context window and longest answer per model (the last two values of each `@prices` row), and the retirement dates. A model the plan names as a candidate or a reference must not be in the legacy list without a note.
3. Open the versioning page, `https://platform.claude.com/docs/en/api/versioning`: the newest `anthropic-version` must equal `@version`; read what the version removed (the 2026-10-21 version removed `temperature`, `top_p` and `top_k`, which is why `Xeito.Chat.Anthropic` sends none).
4. Open the refusals page, `https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback`: the beta header for `fallbacks: "default"` must equal `@fallback_beta`, and the models it lists as taking it must match `@fallbacks` (Haiku 5.5 has refusals but no server-side fallback).
5. Open the structured-outputs page, `https://platform.claude.com/docs/en/build-with-claude/structured-outputs`: `output_config.format` with `type: json_schema` must still be the stable request shape with no beta header.
6. As a second source, `https://models.dev/api.json` carries the same prices under `anthropic.models`; `mix xeito.models.check` leaves Anthropic-backed tiers out, so read the JSON directly.

## 2. OpenRouter candidates and endpoints

**Plan lines.** P3b research table and step 1 (`require_parameters`, `data_collection: "deny"`, `zdr`, `usage.cost`, `GET /api/v1/key`); P4d tier table (`remote` candidate `qwen/qwen3.8-27b`, `remote_frontier` candidate `anthropic/claude-sonnet-5.5`); P4d step 3 (endpoint counts for `qwen/qwen3.8-27b`, the alternatives `z-ai/glm-5.3` and `moonshotai/kimi-k3`, `claude-opus-5.5` under `zdr`, `typesafe/jev-1.14`'s endpoint, `~typesafe/jev-latest` as an alias without one, `typesafe/jev-router`, the decision models' prices); P4d step 4 (Sonnet 5.5's endpoints take no `temperature`, automatic `cache_control`, `GET /api/v1/key` and `GET /api/v1/credits`); P4j steps 3 and 5 (`/api/v1/models/user`, `supported_parameters`, models.dev as the cross-check).

**How to check.**
1. With a remote tier configured in the tier settings (`XEITO_REMOTE_MODEL` and `_KEY_FILE`, or the frontier tier on the `openrouter` backend), run `mix xeito.models.check`. It reads both catalogues and reports differences in window, longest answer, prices and quirks. It needs a dependency tree that resolves (`mix deps.get` clean), which a half-done dependency change can block.
2. For each candidate, read the public endpoint listing, no key needed:
   ```bash
   curl -s https://openrouter.ai/api/v1/models/qwen/qwen3.8-27b/endpoints
   ```
   Count `endpoints`, those whose `supported_parameters` include `logprobs`, those that include `response_format` or `structured_outputs`, and those with both; note whether `temperature` is accepted. Compare with the counts the plan line gives. Do the same for `z-ai/glm-5.3`, `moonshotai/kimi-k3`, `anthropic/claude-sonnet-5.5`, `anthropic/claude-opus-5.5`, `typesafe/jev-1.14`, `~typesafe/jev-latest` and `typesafe/jev-router` (the last two must still have no endpoints for the plan's statements to hold).
3. Read `https://openrouter.ai/api/v1/models` for the candidates' list prices and `modality` (`->decisions` for the decision models), and `https://models.dev/api.json` under `openrouter.models` for the cross-check P4j step 5 describes.
4. The ZDR and data-policy semantics (`provider.zdr`, `data_collection`) are on `https://openrouter.ai/docs/features/zdr`; the key and credits endpoints on the API reference. Read them only when a request shape in `Xeito.Chat.OpenRouter` or `Xeito.Allowance` is in question.

## 3. Hex picks, the project's dependencies and the toolchain

**Plan lines.** PX extraction table (versions and activity of instructor, instructor_lite, req_llm, jido_ai, ash_ai, muex, mutare, kalku_elixir, Exavier, Muzak, ex_crap, statifier, Finitomata, Protean, usage_rules, ex4pm, ash_ex4pm, erlexec, MuonTrap, sbroker, jobs, Poolex); PX steps 1–3 (req_llm's Ollama provider and logprobs; ex_crap's missing `test_coverage` mode and baseline; muex and mutare against `Xeito.Mutate`); PX adopting table (yaml_elixir, anubis_mcp and arbor_mcp, arbor_acp and agent_client_protocol, dune, quickjs and quickbeam, jcs, uuidv7 and uniq, cloudevents, opentelemetry and langfuse, ex4pm, petrex, secret_scan, boundary, tokenizers, bond); Dependencies track (Dependabot and the auto-merge rules); P0 item 1 (OTP and Elixir versions, pinned in `.tool-versions`).

**How to check.**
1. Run `mix hex.outdated` for the project's own dependencies. Then read the open Dependabot pull requests (`gh pr list --author app/dependabot`): a patch or a minor update of a package at 1.0 or later should have merged itself; anything older than a week that did not is a finding on the Dependencies track.
2. For each package the PX tables name, read its Hex record, no key needed:
   ```bash
   curl -s https://hex.pm/api/packages/statifier
   ```
   `releases[0]` is the latest version and date, `retirements` the retired versions, `meta.licenses` the licence, `downloads.recent` the use. Compare with what the plan row says: a version the row quotes, "active" or "no longer maintained", "little used", "release candidate", a licence. A package whose latest release is older than a year while the row calls it active, or newer while the row calls it abandoned, is a finding.
3. For the claims about features, read the changelog the Hex record links (`meta.links`): req_llm's Ollama provider and `logprobs` (PX step 1); ex_crap's `test_coverage` mode and baseline (step 2); the MCP revision anubis_mcp and arbor_mcp implement (adopting table, and section 5 below).
4. Toolchain: compare `.tool-versions` with the latest patch releases of the pinned lines (`gh api repos/erlang/otp/releases`, `gh api repos/elixir-lang/elixir/releases`). Dependabot does not cover these.

## 4. Outside projects the plan cites for a notion

For each: open the repository, read whether it is archived, its licence, its latest release and date, and the changelog since the plan's review date; then look for the specific feature the plan says it has or lacks.

| Project | Cited in | What the plan says | What to look for |
|---|---|---|---|
| pi (`earendil-works/pi`: pi-ai, pi-durable, chord, codemode; npm `@earendil-works/*`) | P4h intro, P4h recovery note, P4j intro and steps 1–4, P4j "not adopted", P5 item 6, P6 item 5, P7 items 8–9, PX step 1 | pi-durable's per-tool `replay`, `requestId`, `migrate`, `viewState`, task ownership; chord's version, `hello`, `WireError`, `cancel`; pi-ai's catalogue, overflow and retry rules, classifier shapes; pi's session JSONL with parent pointers; Codemode | a release that changes the session format, the replay policy or the protocol; the npm versions the plan quotes; a licence change |
| Paperclip (`paperclipai/paperclip`) | P5 item 8, P7 items 10–11, P9 item 7 | run liveness, task watchdogs, heartbeats, the adapter shape (environment in, one run out) | a release since the review date that renames or drops these; a licence change |
| Omnigent (`omnigent-ai/omnigent`) | P4d step 4 (ask thresholds), P4k items 8–9, P6 item 7, P7 item 7 (Polly), P9 item 8 | alpha; cost budget with ask thresholds, stacked policies, brokered credentials, collaboration; no event log, replay, typed decisions or state machines | the alpha badge gone; a feature the plan says it lacks appearing in a release; a licence change |
| critty (`crittylabs/critty`) | P6 item 7, P7 item 7, P9 item 9 | saved resumable reviews, scoped consent, OSC 7501 program status, forms | a release that changes the review format or the OSC code (`internal/tui/program_status.go`) |
| learn and LearnHarness (`amosblomqvist/learn`, `amosblomqvist/learnharness`) | P4c compaction accounting, P4l, P7 item 11 | AGPL-3.0 (learnharness); compaction cutoff rules; the knowledge graph with a coverage ledger; background delivery by steer or wake | a release that changes compaction or the graph; a licence on `learn`, which has none |
| AnyJev (`nokia-applied-research/AnyJev`) | P7 item 3 | Apache-2.0; L0 readout, `POST /v1/decide` gateway, Tacit checkpoints, `level`/`require` | a release that changes the gateway's API or the licence; new checkpoints |
| Fabric (`danielmiessler/fabric`) | P4g intro and tables, P9 item 6 | patterns as filters, strategies, contexts, `--serveOllama` | the flag or the strategies renamed; the comparison table's "no" entries |
| Anthropic's skills (`anthropics/skills`: `webapp-testing`, `mcp-builder`) | P6 item 6, P9 item 5 | Apache-2.0, Playwright in Python; the MCP design guide and evaluation method | the skills present with their `LICENSE.txt`; a rewrite of `mcp-builder` for a newer MCP revision |
| Microsoft's review-loop skill | P7 item 7 | fresh child per pass, severity scale, lenses, the two-pass stopping rule | the plan gives no link and `microsoft/skills` has no skill of that name: find the source and link it |
| caveman (its proxy and `learn`) | P4b intro, P5 item 4 | the gain is in what the model reads; token sinks | unlinked in the plan and the references: find the repository and link it |
| pm4py-mcp (`azizketata/pm4py-mcp`) | P5 item 2 | AGPL-3.0, unmaintained | a commit since the review date (it was last pushed in 2026-04) |
| try (`binpash/try`) | P4k step 7 | an overlay that shows a command's changes before they apply | still maintained when step 7 starts |
| OpenAI Codex command safety, PaSh annotations, NL2Bash | P4k intro and step 4 ([references §8](architecture/references.md#8-shell-command-effects-undo-and-agent-safety)) | per-flag exclusions; annotation shape; the corpus | not weekly: the citations are pinned to commits |
| statifier (`riddler/statifier-ex`) | PX extraction table, Conformance track | version, SCION and W3C tests | the Hex version; the test translations still MIT |

## 5. Protocols, specifications and formats

| Reference | Cited in | Check |
|---|---|---|
| MCP | P4h step 5, P9 item 1, references §8 (ToolAnnotations, schema 2025-06-18) | `gh api repos/modelcontextprotocol/modelcontextprotocol/releases`: the newest dated revision, and its changelog for the handshake, sessions and tool annotations; confirm that the Hex libraries of section 3 implement it |
| ACP (Agent Client Protocol) | P9 item 1, PX adopting table | `gh api repos/agentclientprotocol/agent-client-protocol/releases`: the protocol version and whether a new major schema is in alpha or released |
| CloudEvents | P5 item 6 | `gh api repos/cloudevents/spec/releases`: the newest `ce@` tag (1.0.2 since 2022) |
| RFC 8785, 9457, 9562 | P5 item 6, P9 item 1 | `curl https://www.rfc-editor.org/rfc/rfc8785.json`: `obsoleted_by` and `updated_by` empty |
| W3C PROV, W3C SCXML | P5 item 6, Conformance track | `https://www.w3.org/TR/prov-overview/` and `https://www.w3.org/TR/scxml/`: a newer Recommendation or a superseding note |
| OCEL 2.0 | P1 item 5, P5 items 1 and 6, PX extraction table | `https://www.ocel-standard.org/`: a revision after 2.0; PM4Py's `read_ocel2_sqlite` still in its API |
| pi's session format | P5 item 6 | pi's `packages/coding-agent/CHANGELOG.md` for session-file changes (parent pointers, entry types) |
| OpenTelemetry GenAI conventions, OTLP | P5 item 6 | the semantic conventions' status (experimental or stable) at `https://opentelemetry.io/docs/specs/semconv/gen-ai/` |
| Agent Skills format | P4 status, P4e, P4f step 3 | `https://agentskills.io`: frontmatter fields, the `metadata` convention |

## 6. Ollama

**Plan lines.** P2 item 2 and P3 item 2 (`format` as JSON Schema, `/api/ps`); P4 exit latency (text held back while tools are offered, the reload after keep-alive); P4b item 5 (an over-long prompt is cut from the front, silently, the system prompt first); P4d tier table (`qwen3.8:27b` on the `ollama` backend); P4f step 4 (`/api/tags` digests).

**In the code.** `Xeito.Chat.Window.truncated?/2` recognises a cut prompt by a reported prompt size just over half the window: the rule seen on Ollama 0.32 with a service-wide context length. Later Ollama versions with `num_ctx` set per request or in a Modelfile have been seen to take prompts up to the full window, so the detection may miss or misfire after an upgrade.

**How to check.**
1. `ollama --version` on the reference workstation against `gh api repos/ollama/ollama/releases --jq '.[0].tag_name'`.
2. Read the release notes between the two versions for "context", "num_ctx", "truncat" and the service-wide context-length variable. A note that changes the cut point or makes an over-long prompt an error is a finding on P4b item 5 and on `truncated?/2`.
3. Do not measure the cut point weekly. It is re-measured after an upgrade and at a phase end: send a prompt just under the window and read the server's log for `truncating input prompt`.

## 7. Items deferred on a precondition

Each is a yes-or-no question. "Yes" means the precondition has flipped and the item is due; record it on the item.

| Plan item | Waits for | The question | Where the answer is |
|---|---|---|---|
| P4d step 3, `remote` and `remote_decision` candidates | remote tiers wanted for decisions | Is a `remote` or `remote_decision` tier configured in the tier settings? | the tier settings file; `mix xeito.models.check` |
| P4d step 3, `remote_decision` | Jev reachable through OpenRouter | Does `typesafe/jev-1.14` (or a newer Jev) have an endpoint? | section 2, step 2 |
| P4c step 3 | a session long enough to summarise | Has any run entered `summarising`? | `event_transition.to_state = 'summarising'` in the workspace log (read-only) |
| P4 exit, P9 "after P4", P5 "mining report from the dogfood logs" | two weeks of dogfooding with ≥ 50 runs, five structured machines in daily use | Does the workspace log hold ≥ 50 runs over ≥ 14 days? | `object` rows of type `run` and the event span in the workspace log; the machines-in-use count is a phase-end measurement, not weekly |
| P4f step 5 (embeddings), step 6 (`skill_wide`) | fresh requests measuring below 90% | Has P5's mining of the logged `Skill` decisions reported recall? | P5 status; until then "no" |
| P4f step 7 | enough history and a rule for which signals count | Is there a rule? | P7 status; until then "no" |
| P4h fallback to JavaScript | the step 6 benchmark showing Elixir scripts more than ten points behind | Has step 6 run? | P4h status |
| P4k step 7 | the `contained` effect level | Is `contained` implemented (`rg contained lib/`)? | the code; until then "no" |
| PX step 1 | P4h done | Are P4h steps 5–6 done? | P4h status |
| PX extraction table, OCEL | P5's validation of the layout | Is P5 item 1 done? | P5 status |
| PX adopting table, petrex | the package maturing | More than one release, or regular downloads? | section 3, step 2 |
| PX adopting table, bond | a failure in the pure core no test anticipated | Did dogfooding log one? | the issues from dogfooding |
| P4j step 3, the anchored estimate | logged estimates proving off | Do the logged `tokens_in` disagree with the estimates? | a phase-end measurement, not weekly |
| P4d, `local_decision` as a decider | P7's fine-tuning | Has P7 item 3 produced a model that passes the gate? | P7 status |

## 8. Deliberately not weekly

Measurements are re-run at phase ends, never by this check: latencies (P4 exit, P4d step 4 live costs), eval accuracies and calibration (P2, P3, P3b, P4d step 3, bench 4d), token counts and savings (P4b, P4i), skill recall (P4f), the self-refine comparison (P4g step 6), the Risk corpus and oracle (P4k), the context benchmark (P4i). A fact that a measurement produced stays as measured, with its date, until the next measurement; this check only notes when the thing measured has changed upstream (a model retired, a version bumped) so that the next measurement is scheduled.

Also not weekly: the pinned research citations in [references](architecture/references.md) (papers, commits), the EU AI Act and ISO mapping (Writing track), and the licences of the project's own dependencies, which `mix hex.audit` in `mix ci` covers.

## Routine

1. Run: `mix hex.outdated`, `mix xeito.models.check` (with a remote tier configured), `ollama --version`, the `curl` and `gh api` reads of sections 1–6 (a script in the private companion repository may batch them).
2. Read: the Claude pricing, models, versioning and refusals pages; the OpenRouter endpoint listings; the Hex records; each cited project's releases since the plan's dated review; the release notes of the protocols; Ollama's release notes.
3. Answer section 7's questions, each yes or no.
4. Record: on the plan item that carries the fact, append `(checked YYYY-MM-DD: what changed, and what it means for the item)`; leave items whose facts hold untouched; a stale fact in code (the price table, the truncation rule) gets its note on the plan item and a fix in the next commit that touches that module.
5. Commit the plan with the message `Plan: weekly freshness check YYYY-MM-DD` listing the findings, through the usual gates; nothing operator-specific goes in either file.
