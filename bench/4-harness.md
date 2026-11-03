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

## 4. Code navigation: outline, symbol reads and the project map (2026-09-28)

The task: "Make the TUI's prompt cursor blink, like an editor's cursor." The starting point is Xeito's own code before the blinking cursor existed, as a fresh git repository with compiled dependencies. [`bench/scripts/p4_code_nav.exs`](scripts/p4_code_nav.exs) sends the prompt through a normal session in-process: Intent, the chat machine, Risk and the quick check. Reviews are denied automatically. The large local model is used, with the step limit at 25.

- **A:** harness before this work (`71a5c26`).
- **B:** A plus `read` with `outline`/`symbol`, and a syntax check after `write`/`edit` (`978d673`).
- **C:** B plus the project map in the instructions (`3fcb280`).

Three runs each, interleaved:

| | A | B | C |
|---|---|---|---|
| Runs that reached an edit | 1 of 3 | 0 of 3 | 3 of 3 |
| Step of the first edit | 18 | — | 18, 18, 19 |
| Runs using `outline`/`symbol` | — | 1 of 3 | 2 of 3 |
| Shell commands per run (mean) | 17 | 16 | 14 |
| Input tokens per run (mean) | 465k | 424k | 502k |
| Wall time per run (mean) | 140 s | 131 s | 182 s |
| Finished within the step limit / quick check passed | 0 / 0 | 0 / 0 | 0 / 0 |

An earlier round had a broken workspace, so its quick-check results are invalid. Its step counts still hold: A and B each reached an edit in 1 of 3 runs, which makes A 2 of 6 and B 1 of 6 over both rounds.

Findings:
- **No variant finished the task.** Every run spent about 18 steps exploring, mostly in the TermUI dependency's source, learning how timers and the text input work. It then ran out of steps while editing.
- **With the project map, every run reached the editing stage.** A and B mostly did not. The sample is small, and n = 3 per variant is suggestive rather than conclusive.
- **Outline and symbol reads are used only some of the time.** The model still reaches for `grep -rn` across files, which the outline (one file at a time) does not replace.
- **The edits that were made did not compile.** One left a syntax error, which the new check reported in the same step, but no step was left to fix it. The others used an undefined variable or misused `&1` captures. A failing check at the step limit is only reported: `stopped` turns cannot fix.

What this suggests next:
1. A small fix budget beyond the step limit: after edits, allow a couple of extra steps to repair a failing quick check.
2. The API of the dependencies the project uses (for example `TermUI.*`) in the map, since exploring dependency sources took most of the steps.
3. A step limit that fits unfamiliar-library tasks for a local model, or a planning step before exploring.

## 5. P4b: tool-output shaping and elision, benchmark D (2026-09-30)

The same task and setup as §4. Three harness versions, three runs each, interleaved. The starting workspace passes the quick check before the run.

- **C:** the project map (`3fcb280`), the best variant of §4.
- **S:** C plus tool-output shaping (`d7fc9fc`).
- **D:** S plus eliding old tool output (`9258fa7`).

| | C | S | D |
|---|---|---|---|
| Input tokens per run (mean) | 606k | 327k (−46%) | 230k (−62%) |
| Wall time per run (mean) | 211 s | 115 s | 118 s |
| Runs with an edit applied | 3 of 3 | 0 of 3 | 0 of 3 (two edits, both "old_text not found") |
| Step of the first edit | 10, 17, 14 | — | 23, 24 |
| Line-range reads (`lines`) per run | 0 | 6–7 | 5–10 |
| Results read back (`result`) | — | 1 | 0 |
| Finished within the step limit and passed the quick check | 1 | 0 | 0 |

Findings:
- **Tokens: the P4b target is met.** Shaping and elision together cut input tokens per run by 62%, and runs take about half the time. Elision did not make the model fetch results back.
- **The task: a regression, the other half of the exit criterion fails.** With shaping, whole-file reads became an outline and the first part. The model then paged through files with `lines` reads, one step per page, and reached the step limit before editing (S) or just after starting (D). Tokens are no longer the constraint; steps are.
- **Both D edits failed with "old_text not found".** The model reconstructed the text to replace from memory, after the read that showed it had been shortened or elided.
- **C3 is the first run to pass the quick check within the step limit, but it does not do the task.** It makes the `> ` prompt blink instead of the cursor. Compiling is a weak check of success.

What this points to (added to P4b as item 4):
1. **Shape reads by purpose, not size.** Keep the project's own files whole up to a much larger limit (the model reads them to edit them), and shape dependency sources and generated files (`deps/`, `node_modules/`), which are read to learn an API.
2. **When an edit misses, show the nearest match.** Answer "old_text not found" with the closest region of the file and its line numbers, so one step recovers instead of a re-read and a retry.
3. **Judge success on behaviour.** Add a task-specific acceptance check to the benchmark, for example a test that the cursor cell toggles, next to the quick check.

## 6. P4b follow-ups, benchmark D rerun (2026-09-30)

Two follow-ups from §5 (`0e0fddc`):
- Reads are shaped by purpose: dependency sources and generated files from 400 lines, the project's own files only past 2,000.
- A missed edit is answered with the closest region of the file.

The same task and setup, with harness E (both follow-ups, plus shaping and elision) against C (project map only), three runs each, interleaved:

| | C | E |
|---|---|---|
| Input tokens per run (mean) | 649k | 240k (−63%) |
| Wall time per run (mean) | 230 s | 134 s |
| Runs with an edit applied | 3 of 3 | 2 of 3 (§5 D: 0 of 3) |
| Step of the first edit | 12, 12, 13 | 22, —, 18 |
| Edits that missed their text | 0 | 0 |
| Quick check passed | 1 of 3 | 0 of 3 |

Findings:
- **Token savings hold at 63%**, and most runs reach editing again. None of E's edits missed its text, so the nearest-match answer was never needed here.
- **Editing still starts later than without P4b** (steps 18–22 against 12–13), and none of E's runs passed the quick check.
- **The cause is visible in the reads.** The project file is now read whole, but elision later stubs that read, and the model re-reads the file in slices. One run read `lib/xeito/tui.ex` in eight line ranges. Elision should keep the latest read of a project file whole, eliding only older reads, reads of dependency sources, and shell output.

## 7. Keeping project reads whole, benchmark D rerun (2026-10-01)

Elision now keeps the latest whole read of each of the last three project files read (`3f54cea`, chat machine 0.4.0). The same setup, with harness F (all of P4b) against C (project map only), three runs each, interleaved:

| | C | F |
|---|---|---|
| Input tokens per run (mean) | 597k | 314k (−47%) |
| Wall time per run (mean) | 180 s | 158 s |
| Runs with an edit applied | 2 of 3 | 3 of 3 |
| Step of the first edit | 20, 17, — | 22, 12, 17 |
| Edits that missed their text | 0 | 0 |
| Finished within the step limit and passed the quick check | 0 of 3 | 1 of 3 |

Findings:
- **With all of P4b, runs reach editing as reliably as without it.** Editing starts no later, and one run finished in 22 steps.
- **Savings fall from 63% (§6) to 47%**, because the latest read of the file being edited now stays in every request. That is just short of the "halved" exit target, and the trade is worth it: §5 and §6 showed what eliding that read costs.
- **The model still reads parts of the file** it already has whole (two runs, four line ranges each), probably to anchor its edits. Most of the slicing seen in §6 is gone.
- **The finished run (F2), like C3 in §5, blinks the `> ` prompt marker instead of the text cursor.** "The TUI's prompt cursor" is ambiguous, and both readings compile. The benchmark needs an unambiguous task and a behavioural acceptance check before success rates mean anything.

P4b status: the token half of the exit is nearly met (−47% against ≥ 50%), and the editing half is met.

## 8. An unambiguous task and an acceptance check, benchmark D rerun (2026-10-01)

§7's finished runs blinked the `> ` marker, not the text cursor. So the task now reads: "In the TUI (`lib/xeito/tui.ex`), make the text cursor of the input field blink like an editor's cursor: shown and hidden in turn, about twice a second. Keep the `> ` prompt marker as it is."

Success is judged by [`bench/acceptance/cursor_blink_test.exs`](acceptance/cursor_blink_test.exs), copied into the workspace only after the run:
- It drives `Xeito.Tui` the way TermUI's runtime does: `init` against a fake daemon, then the timer, interval and send_after commands and plain messages fed back.
- It renders three seconds of frames.
- It passes when the input's cursor cell is drawn in some frames and hidden in others (2–12 toggles), and every frame shows the marker.
- Validated before use: current Xeito passes; the code before the cursor existed, F2's and C3's marker blinks all fail.

Harness F (all of P4b, `3f54cea`) against C (project map only, `3fcb280`), three runs each, interleaved:

| | C | F |
|---|---|---|
| Input tokens per run (mean) | 553k | 307k (−44%) |
| Wall time per run (mean) | 162 s | 136 s |
| Runs with an edit applied | 1 of 3 | 2 of 3 |
| Step of the first edit | 23, —, — | —, 12, 18 |
| Acceptance check passed | 0 of 3 | 0 of 3 |
| Why the check failed | no blinking (3) | no blinking (1), does not compile: `undefined variable "state"` (2) |

Findings:
- **On the unambiguous task, neither variant succeeds within 25 steps.** The success half of P4b's exit ("no loss of success") holds, but trivially: there is no success to lose. With 0 of 3 on both sides, the benchmark cannot measure task success at this step budget and model size.
- **P4b's effect on the way there is consistent with §7:** 44% fewer input tokens, shorter runs, and more runs reaching an edit (2 of 3 against 1 of 3).
- **Both F runs that edited stopped at the step limit with code that does not compile.** The quick check reported it, but a stopped turn cannot fix anything. This is the case for the fix budget noted in §4: a couple of steps past the limit to repair a failing check.

To make task success measurable, any of these would do:
- the fix budget;
- a larger step limit for this benchmark;
- the dependency APIs in the project map, so fewer steps go into reading TermUI.

## 9. P4g: self-refine against a single call (2026-10-31)

Does a draft → critique → revise strategy (`Xeito.Machines.SelfRefine`, with the `Refine` decision on the critique, at most two revisions) beat one chat call on prose tasks? `bench/scripts/p4g_strategies.exs` ran the twelve tasks of `bench/strategies/set.jsonl` both ways on the local tier (qwen3.8:27b through Ollama, no tools), and the same model judged each pair twice with the order swapped; a variant wins a task only when it wins both orders. The raw results (every answer and judgment) are kept in the private companion repository, as they quote the model at length; one word of the set was changed after the run, to pass the public repository's guard.

| Task | Verdict | Judgments (A = single first, then swapped) | Tokens single | Tokens refine | s single | s refine |
|---|---|---|---|---|---|---|
| condense | refine | B/A | 231 | 1208 | 10 | 5 |
| release-notes | tie | A/A | 622 | 1283 | 2 | 16 |
| explain-code | tie | B/B | 1015 | 1923 | 3 | 13 |
| polite-email | tie | B/B | 1280 | 421 | 2 | 3 |
| action-items | tie | A/A | 1547 | 599 | 2 | 3 |
| title | tie | A/A | 1855 | 381 | 1 | 2 |
| translate | tie | A/A | 2072 | 907 | 2 | 5 |
| commit-message | tie | B/B | 2321 | 1105 | 2 | 9 |
| reviewer-questions | single | A/B | 2596 | 1207 | 2 | 8 |
| bullets-to-paragraph | tie | A/A | 2842 | 375 | 1 | 3 |
| error-plain | refine | B/A | 3065 | 452 | 2 | 5 |
| shorten-announcement | single | A/B | 3999 | 491 | 11 | 3 |

**Result:** refine 2, single 2, tie 8; wall time 40 s against 75 s. Four of the ties are the judge preferring the same position both times, the position bias the swap is there to cancel. No gain, at twice the time: the strategy does not ship as a `--strategy` flag. The machine stays as an experiment (`mix xeito.run --machine self_refine`), and the script repeats the measurement with another model or set. The `Refine` decision passes its gate on `local` (14 examples, accuracy 1.0; the Laya tier 0.5, as for every type so far).

## 10. P4h: scripts against plain tools (2026-11-03)

Does the `script` tool pay on busywork? Three requests on real material, each one chat turn on the local tier (qwen3.8:27b through Ollama), run two times in three variants: the plain tools (`read`, `bash`, `write`, `edit`), the same with `script` offered beside them, and `script` as the only tool. `bench/scripts/p4h_workspaces.sh DIR` builds the workspaces and `bench/scripts/p4h_scripts.exs DIR/tasks.json OUT.json 2` runs them; a command Risk sends to review is approved at once and counted as decided by a human.

| Task | Material | Request | Success check |
|---|---|---|---|
| todos | the req package (`deps/req`, 7 kLOC, 10 TODO comments) | classify every TODO/FIXME under `lib/` by urgency, as a table | every `file:line` in the answer |
| ci_logs | the failed-step logs of three CI runs of elixir-lang/elixir (`gh run view --log-failed`: 855 KB, 295 KB, 67 KB) | group the failures by cause, with the runs and jobs each hit; a log may show no failure | the three causes named (`Map.update!/3`, `to_existing_atom`, `custom shutdown`) |
| issues | twelve open issues of elixir-lang/elixir as JSON (11 KB) | rate each issue's clarity 1–3 with a reason, as a table | every number rated in range |

Per run (turns are model calls; calls are tool effects, children of scripts included; rules and human count Risk decisions by rule and reviews; failed counts effects that returned an error; scripts counts `script` effects):

| Task | Variant | Run | Success (coverage) | Turns | Tokens | s | Calls | Rules | Human | Failed | Scripts |
|---|---|---|---|---|---|---|---|---|---|---|---|
| todos | plain | 1 | ok (1.00) | 5 | 25 226 | 31 | 11 | 1 | 0 | 0 | 0 |
| todos | plain | 2 | ok (1.00) | 6 | 32 457 | 29 | 12 | 3 | 0 | 0 | 0 |
| todos | script offered | 1 | ok (1.00) | 5 | 27 456 | 29 | 12 | 1 | 0 | 0 | 0 |
| todos | script offered | 2 | ok (1.00) | 8 | 52 314 | 33 | 14 | 4 | 0 | 0 | 0 |
| todos | script only | 1 | ok (1.00) | 8 | 41 955 | 35 | 17 | — | 0 | 1 | 7 |
| todos | script only | 2 | ok (1.00) | 9 | 46 850 | 48 | 9 | — | 0 | 4 | 5 |
| ci_logs | plain | 1 | ok (1.00) | 26 | 404 783 | 299 | 58 | 56 | 2 | 2 | 0 |
| ci_logs | plain | 2 | no (0.67) | 26 | 274 356 | 162 | 32 | 15 | 17 | 1 | 0 |
| ci_logs | script offered | 1 | no (0.33) | 23 | 270 460 | 129 | 17 | 15 | 2 | 0 | 0 |
| ci_logs | script offered | 2 | no (0.33) | 23 | 402 658 | 171 | 39 | 39 | 0 | 10 | 0 |
| ci_logs | script only | 1 | no (0.00) | 9 | 19 709 | 36 | 4 | — | 0 | 5 | 5 |
| ci_logs | script only | 2 | ok (1.00) | 26 | 387 644 | 130 | 24 | — | 0 | 24 | 24 |
| issues | plain | 1 | ok (1.00) | 2 | 5 992 | 14 | 1 | 0 | 0 | 0 | 0 |
| issues | plain | 2 | ok (1.00) | 2 | 6 010 | 13 | 1 | 0 | 0 | 0 | 0 |
| issues | script offered | 1 | ok (1.00) | 2 | 6 955 | 14 | 1 | 0 | 0 | 0 | 0 |
| issues | script offered | 2 | ok (1.00) | 2 | 6 967 | 13 | 1 | 0 | 0 | 0 | 0 |
| issues | script only | 1 | no (0.08) | 8 | 11 804 | 20 | 1 | — | 0 | 3 | 4 |
| issues | script only | 2 | no (0.33) | 11 | 37 405 | 29 | 4 | — | 0 | 3 | 7 |

Means over the six runs of each variant:

| Variant | Successes | Coverage | Turns | Tokens | s | Calls | By rule | Human | Failed | Scripts |
|---|---|---|---|---|---|---|---|---|---|---|
| plain | 5/6 | 0.94 | 11.2 | 124 804 | 91 | 19.2 | 12.5 | 3.2 | 0.5 | 0 |
| script offered | 4/6 | 0.78 | 10.5 | 127 802 | 65 | 14.0 | 9.8 | 0.3 | 1.7 | 0 |
| script only | 3/6 | 0.57 | 11.8 | 90 895 | 50 | 9.8 | — | 0 | 6.7 | 8.7 |

A script's commands are not Risk decisions: a command safe by rule runs, any other fails inside the script, so the rules column is empty for script children and every one of their 9.8 calls per run ran by rule. With the plain tools, 65% of the calls were decided by rule and the rest went to review (`grep` and `sed` with flags the rules do not know, mostly), approved here at once.

**Result: the exit criteria are not met, and the local model does not use the tool.**

- **Offered beside the plain tools, `script` is never chosen.** In the six runs here, and in two earlier runs of the same set (twelve more), the model made no script call. The tool's description says what it is for; this model still reaches for `bash` and `read` it knows. The "script offered" variant is the plain variant with a longer tool list: same turns, 7% fewer calls, one more failure (the ci_logs runs hit the 25-turn cap with two of three causes found).
- **With `script` the only tool, scripts run, and mostly fail.** 6.7 of the 9.8 calls per run returned an error. The causes, from the logs of the workspaces: the model matches a call's result against a shape of its own (`{:ok, out} = Script.bash(...)`, `result.output`) rather than the `%{"exit_status" => n, "output" => text}` map the tool description gives, so 24 of 24 scripts in one ci_logs run raised a `MatchError`; the model still answered that run correctly, because the exception's message carries the unmatched value, which is the command's output. There is no JSON decoder in the sandbox (`Jason` is not there, `JSON` is not on the allow-list, `Code.eval_string` is restricted), so both issues runs rated from fragments of raw text. Reading an 855 KB log into one binary and splitting it hits the heap limit (10 M words) or the reductions limit (5 M). `Access` on a list by index, twice.
- **Where scripts worked, they did not save turns.** The todos task took 5–6 model turns with the plain tools and 8–9 with scripts only, the extra ones spent on the failed attempts; a successful script did in one call what `grep -n` plus six `read`s did, but the model did not plan it that way. Tokens per run were lower with scripts only (91 k against 125 k) and wall time was shorter (50 s against 91 s), at half the success.
- **The exit criteria.** "At least five times fewer model turns at equal or better success": turns are equal and success is lower. "Elixir scripts within ten points of JavaScript ones": not measured. Neither pi's Codemode nor a JavaScript sandbox is in reach here (Xeito has no JavaScript runtime and pi is not installed on the reference workstation); the comparison stays open rather than being faked.

**What the benchmark asks for next**, in order of expected effect:
1. The result shapes. A model trained on Elixir expects `{:ok, value}` and `{:error, reason}` from a call that can fail, and atom keys. The API could return those (the `%{"ok" => …}` maps were chosen for the JSON protocol, not for the model) or the tool description could carry one worked example, which this model did not get from prose.
2. `JSON` on the allow-list: `JSON.decode/1` and `encode/1` are pure, and half of busywork arrives as JSON.
3. Limits sized for real files: a log of a megabyte must fit; raise the heap, or give scripts a line-wise `read` so a file never has to be one binary.
4. Getting the tool used at all: on this model, offering `script` changes nothing. A routing rule (a request that names "every" file, comment or issue of a repository goes to a script-first turn) or a one-line instruction in the system prompt would be the next experiment, after 1–3, since a script that fails is worse than none.

Until those are tried, `script` stays offered (it costs nothing when unused) and the measurement stands as the baseline for the next run of the same script.
