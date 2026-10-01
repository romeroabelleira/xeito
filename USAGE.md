# Using Xeito

A hands-on guide: set up the tiers, start the daemon, work in the TUI, and inspect what happened. For the ideas behind it, read the [design doc](docs/design.md). For the current state of the project, see the [implementation plan](docs/implementation-plan.md).

> Xeito is pre-release software. Commands and file formats may still change between phases.

## 1. What runs where

```
  you ──► xeito TUI / line client ──► xeitod (daemon) ──► machines (state machines, logged)
                 JSON Lines over a                        │
                 private Unix socket                      ├─► small tier  llama-server (CPU)
                                                          ├─► large tier  Ollama (GPU)
                                                          └─► off-box     OpenRouter / Claude API (opt-in)
```

- **xeitod** holds everything: sessions, runs, and the event log. Clients are thin, so closing the TUI never stops a run.
- Each project keeps its own log in `<project>/.xeito/log.sqlite`. It is excluded from version control by an automatic `.xeito/.gitignore`.
- Nothing listens on the network. The socket lives in a private directory (`~/.xeito/run/`, mode 0700).

## 2. Setup

### Toolchain

Xeito is Elixir/OTP. The pinned versions are in `.tool-versions`, and [mise](https://mise.jdx.dev) or asdf installs them:

```bash
mise install
mix deps.get
mix test
```

### Model tiers

Tiers are configured through environment variables, read at startup by `config/runtime.exs`. A tier without a URL counts as unavailable, and decisions skip it. A practical minimum is the large tier alone:

| Variable | Tier | Example |
|---|---|---|
| `XEITO_OLLAMA_URL`, `XEITO_LARGE_MODEL` | large (GPU, also the chat model) | `http://127.0.0.1:11434`, `qwen3.6:27b` |
| `XEITO_KEEP_ALIVE` | how long Ollama keeps the model in VRAM after the last request | `5m` (default `10m`) |
| `XEITO_LLAMA_URL`, `XEITO_LLAMA_KEY_FILE`, `XEITO_SMALL_MODEL` | small (CPU, `llama-server`) | `http://127.0.0.1:8081` |
| `XEITO_LAYA_URL`, `XEITO_LAYA_KEY_FILE` | System One (`laya-serve`) | `http://127.0.0.1:8082` |
| `XEITO_OPENROUTER_KEY_FILE`, `XEITO_OPENROUTER_MODEL`, `XEITO_OPENROUTER_PROVIDERS`, `XEITO_OPENROUTER_ZDR` | OpenRouter (off-box) | `qwen/qwen3.6-35b-a3b` |
| `XEITO_ANTHROPIC_KEY_FILE`, `XEITO_REMOTE_MODEL` | remote Claude (off-box) | `claude-opus-5` |
| `XEITO_SOCKET` | the daemon socket | default `~/.xeito/run/xeito.sock` |

**Keys are never put in variables.** The `*_KEY_FILE` variables name a file that contains only the key, with mode 0600. For example, with the 1Password CLI:

```bash
op read "op://Private/OpenRouter/credential" > ~/.config/xeito/openrouter.key && chmod 600 ~/.config/xeito/openrouter.key
```

Keep the variables in one file that both your shell and the service can source:

```bash
# ~/.config/xeito/tiers.env
export XEITO_OLLAMA_URL=http://127.0.0.1:11434
export XEITO_LARGE_MODEL=qwen3.6:27b
export XEITO_KEEP_ALIVE=5m
export XEITO_LLAMA_URL=http://127.0.0.1:8081
export XEITO_LLAMA_KEY_FILE="$HOME/.config/xeito/llama_api_key"
```

The [reference deployment](docs/architecture/09-reference-deployment.md) explains how to choose models and hardware. [`deploy/`](deploy/) has example systemd units for `llama-server` and for the daemon.

## 3. Start the daemon

In a terminal, for trying things out:

```bash
source ~/.config/xeito/tiers.env
mix xeito.daemon
```

As a service that stays out of the way of desktop work (lower CPU weight and priority, capped memory, which also applies to the commands the agent runs):

```bash
cp deploy/systemd/xeitod.service.example ~/.config/systemd/user/xeitod.service   # then edit the paths
systemctl --user daemon-reload && systemctl --user enable --now xeitod
journalctl --user -u xeitod -f
```

When idle, the daemon uses about 100 MB of RAM and no CPU. Sessions without activity close after two hours; they're rebuilt from the log the next time you use them. A project's log closes after 30 minutes without use and reopens on its own.

## 4. Your first session

```bash
mix xeito.tui --cwd ~/src/my-project
```

The screen has four parts:
- a header with the project and the active machine
- the transcript
- the prompt line
- a status line with state, elapsed time, tier, number of decisions and spend

Type a request and press Enter:

```
> what does lib/pricing.ex do?
◆ intent: explain (large 1.00)
  → Chat · no dedicated machine for intent explain
    read lib/pricing.ex
The module computes gross prices …
✓ answered
```

The typing position is a solid yellow block. It blinks while you're idle, and stays solid while you type.

Each `◆` line is a **typed decision**. Risk decisions are shown differently: the command they apply to gets a coloured dot in the left gutter, like a breakpoint, with the decision's confidence beside it in small digits. Green means safe, yellow means it waits for your review, red means forbidden:

```
●¹⁰⁰ $ grep -rn "cursor" lib
●⁹⁴ ? review: run `rm -rf _build` — approve with y, deny with n
```

Other `◆` lines are other typed decisions. It shows its value, the tier that decided and its confidence. Everything the model does goes through a small set of tools (`read`, `write`, `edit`, `bash`), and each tool call is a logged effect.

### The status bar

Above the status line, the TUI shows one more line, the status bar. Toggle it with **Ctrl-T** or `/statusbar`, or start without it using `--no-status-bar`. It is filled in priority order until it fills the terminal's width: the latest decision and reply, tokens, GPU, models and git come first; queues and CPU are the first to give way on a narrow terminal.

```
 large qwen3.6:27b unload 4:58 │ git main 2 changed ↑1 │ 3.4k→84 tok · ctx 1.6k/81.9k │ risk rule 3 ms │ reply 1.1 s (first 291 ms)
```

| Part | Meaning |
|---|---|
| `GPU` | the discrete GPU: VRAM used/total, utilisation, power, hottest temperature (Linux, AMD via sysfs) |
| `large …` | the model resident in Ollama, and how long until the keep-alive unloads it (`idle (not loaded)` after that) |
| `small ✓ 0/4` | the CPU `llama-server` is up, with busy/total slots; `S1` is the System One service |
| `CPU … RAM …` | processor utilisation and load, memory in use |
| `chat 2 · large 1 · rule 1` | calls in this session: chat turns, and decisions by who made them |
| `tok`, `ctx` | tokens in → out, and the last chat prompt against the model's context window |
| `risk rule 3 ms` | the latest decision: its type, who decided, and how long it took (including escalation) |
| `reply` | the latest model reply: total time, and time to its first chunk (what you wait for before text appears) |
| `det` | the determinism budget: the share of transitions taken by code or rules rather than a model or a human |
| `$ · J` | spend on off-box tiers, and estimated energy of local decisions |
| `git` | the project's branch, uncommitted entries, and commits ahead/behind its upstream |
| `budget` | the off-box budget left for the current run, of the limit per run, or `off-box off` when policy keeps everything local |
| `queue` | tiers with calls in flight (+ waiting) |

The hardware and model line comes from the daemon, which only polls (every 2 s) while a client shows the bar; hidden or closed, it costs nothing. The git and budget segments come from the session. They refresh after every turn, and every 10 s while the bar is shown.

**Choose what it shows.** Each part is a segment you can hide or show again:

```
> /statusbar segments              list them (hidden ones are marked ·)
> /statusbar hide cpu,queue,cost
> /statusbar show cost
> /statusbar off                   (or on, or reset)
```

The choice is saved in `~/.config/xeito/tui.json` (or `$XDG_CONFIG_HOME/xeito/tui.json`; set `XEITO_TUI_CONFIG` to use another file), so the next TUI starts the same way. The segments are `gpu models cpu git calls tokens decision reply det cost budget queue`.

**Quit** with `/quit` (or `/exit`, Ctrl-D, Ctrl-C). The session keeps running in the daemon. Reattach with the id printed at the top:

```bash
mix xeito.tui --cwd ~/src/my-project --session ses-abc123
```

Prefer plain lines (logs, pipes, a minimal SSH session)? `mix xeito.chat` takes the same options, and you answer reviews with `y` / `n`.

## 5. Everyday examples

### Fix a failing test

```
> the checkout test is red again, fix it
◆ intent: edit (large 1.00)
  → FixFailingTest · intent edit, failing test
· reproduce
  $ mix test
    exit 2 · 1 test, 1 failure
◆ triage: code_bug (large 0.99)
· planning
  ↳ delegating to Chat
    read test/checkout_test.exs
    read lib/checkout.ex
    edit lib/checkout.ex
      - Enum.sum(prices) * tax
      + Enum.sum(prices) * (1 + tax)
· verifying
  $ mix test
    exit 0 · 42 tests, 0 failures
✓ done · …
```

The request is routed to a dedicated machine:
1. Reproduce the failure.
2. Triage it: `flaky`, `code_bug`, `test_bug` or `env_problem`.
3. Hand the fix to a chat sub-run.
4. Verify by running the tests again.

A flaky failure is re-run instead of edited. An environment problem, or a triage nobody is sure about, asks you: fix the environment yourself, then `/approve` (or `y`) to continue, or `/deny` (`n`) to stop. The test command is detected from the project: `mix test`, `npm test`, `pytest`, `cargo test`, `go test ./...`, otherwise `make test`.

### Ask, explain, plan

Questions, explanations and "how would you approach…" requests go to the **free chat machine**: pi's agent loop, drawn as a statechart. It reads files and runs harmless commands on its own:

```
> which modules call Pricing.total/2?
> explain the supervision tree in lib/my_app/application.ex
> plan how to split the Accounts context; don't change anything yet
```

**Edits are checked before the answer.** When a turn has changed files, a *quick check* runs before the model's answer reaches you. It only asks whether the code still builds, and takes a few seconds:
- Mix: format and compile warnings. Rust: `cargo check`. Go: `go build ./...`. TypeScript: `tsc --noEmit`. Other `package.json` projects: the lint script. Python: `ruff check`, if configured.
- Your own quick check wins: a `"check.quick"` alias in `mix.exs`, or a `check-quick` Makefile target.
- Projects with none of these aren't checked.

The full suite (tests, linters) is what "run the checks" and the `check` machine are for. If the quick check fails, the model sees the output and gets up to two tries to fix it. This also applies when the turn has used up its steps: fixing gets up to four extra model turns, so a turn doesn't end on code that doesn't build when a fix is within reach. A turn that still fails says so at the end of the answer (`⚠ The checks still fail …`).

**Navigating code.** Each chat turn's instructions include a *project map*: the kind of project (Mix, npm, Cargo…), its top-level directories, and its dependencies with where their sources are. For Elixir, it also lists every module under `lib/` with its file and, if they fit, its first doc line and public functions. The model starts out knowing where things live. For Elixir files, the model can ask `read` for an outline instead of the file: the modules, functions and tests, each with its line range. It can then read one definition by name (`init/1`, `Xeito.Tui.view/1`). It needs far fewer `grep` and `sed -n` steps to find its way. After every `write` or `edit`, the file is parsed (Elixir, JSON). If it no longer parses, the model is told in that same step, before it moves on. The transcript shows these as `outline lib/x.ex`, `read lib/x.ex · init/1`, and `⚠ no longer parses: …`.

**Long tool output is shortened for the model.** Shell output loses colour codes and progress redraws, and runs of similar lines collapse. Test and compiler output keeps its failures, errors and summary, and search results are grouped by file. Dependency sources and generated files (`deps/`, `node_modules/`, `_build/`, …) over 400 lines arrive as their outline (Elixir) or first part, with how to read the rest (`lines: "121-420"`, `symbol`). The project's own files stay whole up to 2,000 lines, because the model reads those to edit them. An edit whose `old_text` isn't found is answered with the closest region of the file, ready to copy. The transcript and the log keep the full output. The model can fetch it back with `read` and `result:`, using the reference shown at the end of shortened output. Older tool output is also dropped from what is resent to the model on each step: past the latest four outputs, long ones become one-line stubs, six at a time. Each stub says what the output was and how to read it again.

The model can't edit fetched dependencies, build output, git's data or Xeito's log (`deps/`, `_build/`, `node_modules/`, `.git/`, `.xeito/`). Dependencies aren't rebuilt from edited sources and are replaced on the next fetch, so such an edit would look done but never take. The model is told this and asked to change the project, or to propose a fork or an upstream patch.

**When a turn runs out of steps,** the model gets one last turn without tools to tell you what it found, what's left and what it would do next. Then a short "go ahead" or "continue" picks the work up again, with tools. The model also doesn't get to repeat itself: an identical tool call already made in the same turn isn't run again, and a turn whose tool calls keep failing ends with the model's summary.

The conversation carries over between turns in a session. An `AGENTS.md` at the project root is added to the model's instructions, so put conventions there, for example "run `mix format` after editing" or "never touch `priv/repo/migrations`".

### Run a command

```
> /run mix test test/accounts_test.exs:42
```

`/run` executes exactly what you typed, once, with no model involved. Natural requests like "run the tests" do the same through the `run_tests` machine.

### Commands that need your approval

Every shell command the model proposes first passes the **Risk** decision:
- **Rules** decide the obvious cases: `ls`, `git status` and `mix test` are safe, while `rm -rf /` and `curl … | sh` are forbidden.
  Read-only commands are safe, including in pipelines: `grep`, `find` without `-exec`/`-delete`, `sed -n '10,20p'`, `cat`, `head`, and `cd` into a subdirectory. Quotes are respected (`grep "a\|b"` is a single command), and output may go to `/dev/null` or another stream (`2>&1`). A redirect into a file, or command substitution, always goes to review.
- **The model** judges the rest, and it can only make a verdict more cautious.
- **Safe** commands run.
- **Forbidden** ones never run, and the model is told why.
- Anything **in between waits for you**:

```
◆ risk: review (large 0.94)
? review: run `rm -rf _build` — approve with y, deny with n
```

In the TUI, press `y` or `n` while the prompt is empty. In any client, use `/approve` or `/deny`. A denied command is reported to the model, which then continues without it.

### Run the checks

```
> run the checks and fix what fails
◆ intent: run (large 0.95)
  → Check · intent run, checks
  $ mix ci
    exit 1 · … 3 files are not formatted
  ↳ delegating to Chat
    $ mix format
· checking
  $ mix ci
    exit 0
✓ done · Checks pass after 1 fix run(s).
```

The check command is taken from the project, in this order:
1. A `ci` alias in `mix.exs` (`mix ci`).
2. A `check` target in the Makefile (`make check`).
3. For Mix projects: format check, compile with warnings as errors, then tests.
4. `npm run lint && npm test` when `package.json` has a lint script.
5. Otherwise, the test command.

Failures go to a chat run, up to three attempts. After that, it asks you: fix the problem by hand and `/approve`, or `/deny` to stop.

### Commit

```
> commit these changes
  → Commit · intent run, commit
· drafting
Fix calculation of gross price in pricing module
* Correct formula to add tax rate to 1 before multiplying by net price
? review: commit 1 file: Fix calculation of gross price in pricing module — approve with y, deny with n
✓ done · Committed fd05b3d Fix calculation of gross price in pricing module
```

The model only drafts the message; the git commands are fixed. Staged changes are committed as they are. With nothing staged, everything is staged first (`git add -A`, which respects `.gitignore`), so check the file count in the review line. Your commit hooks run as usual.

### Skills

Xeito reads skills in pi's format ([Agent Skills](https://agentskills.io/specification)): a directory with a `SKILL.md` that starts with `name` and `description` frontmatter. It looks in the project's `.pi/skills/` and `.agents/skills/`, then in `~/.pi/agent/skills/` and `~/.agents/skills/` ([pi's skill locations](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/skills.md)), so skills you already use with pi work unchanged.

```markdown
---
name: py-inventory
description: List every Python function with a one-line summary. Use when asked for an overview of the code.
---
1. Find the Python files. 2. Read each. 3. Answer with a table: file, function, summary.
```

- **Automatic:** the model sees each skill's name and description, and loads the instructions with its `skill` tool when a task matches. That tool reads only files inside the skill's own directory.
- **Explicit:** `/skill:py-inventory` or `/skill:py-inventory only pricing.py`.
- `disable-model-invocation: true` in the frontmatter hides a skill from the model; it can then only be run explicitly.
- Skills are re-read on every turn, so edits apply immediately.
- A skill's commands still pass the Risk decision like any other.

### List the machines

```
> /machines
machine           version  runs  done  failed  last run (UTC)
fix_failing_test  0.5.0    3     3     0       2026-09-28 10:12
    reproduce a failing test, triage it, delegate the fix to chat, verify
    routed from: intent edit + a failing, red or broken test · /machine fix_failing_test
…
```

Every machine is listed with what it does and how requests reach it. The usage counts come from this project's log. Clients can get the same data as JSON with the API's `machines` command.

### Start a machine directly

```
> /machine fix_failing_test
> /machine chat summarise the open TODOs in lib/
> /machine run_tests
> /machine check
> /machine commit
```

## 6. Seeing why

| Command | Shows |
|---|---|
| `/why` | the last decisions of the session: type, value, who decided (rule, small, large, human), confidence, model, latency |
| `/help` | every command |
| `/machines` | the machines, their routing, and their use in this project |
| `/quit` | close the client; the session keeps running in the daemon |
| status line | current state, tier of the last decision, number of decisions, spend on off-box tiers |

### Step mode and breakpoints

Step mode lets you watch a machine decide, one result at a time:

```
> /step
step mode on
> the login test fails
‖ paused in reproduce before bash exit 1 — /next · /decide <value> · /continue
> /next                        (or just Enter in the TUI)
‖ paused in triage before Triage: flaky (large 0.83) — /next · /decide <value> · /continue
> /decide code_bug
```

`/decide` replaces the model's answer with yours. It's logged with `actor: :human` and keeps the model's original answer as evidence, which makes it a labelled example for evaluating and training deciders later.

Breakpoints pause only where you care:

```
> /break decision:risk          pause at every Risk decision
> /break conf<0.7               pause when any decision is unsure
> /break state:verifying        pause when a result arrives in a state
> /break clear
> /continue                     turn step mode off and let the run go on
```

Delegated sub-runs (the chat run inside `fix_failing_test`) inherit the settings. The internal escalation between tiers never pauses.

### Spend limits

```
> /budget 0.10
```

This sets the most a single run may spend on off-box tiers, in USD (default 0.50). Once the budget is used up, off-box tiers are skipped.

## 7. Where the data goes

**Everything stays on the machine by default.** OpenRouter and the Claude API are *off-box tiers*: switched off unless configured, never used for inputs tagged local-only, and never used for the Risk decision. To use them for public or synthetic data, enable them in the application config:

```elixir
# config/config.exs (or a deployment-specific config)
config :xeito, :policy, remote: :allowed, locality: :public, max_usd_per_run: 0.25
```

With that config, typed decisions that list an off-box tier among their deciders may use it. OpenRouter requests always ask for providers that neither store nor train on prompts. Section 9 shows how to evaluate an off-box tier without touching the policy.

## 8. Inspecting the log

The log is an [OCEL 2.0](https://www.ocel-standard.org/) database in SQLite: every state change, effect, decision and cost. Some starting points, run from the project root:

```bash
sqlite3 -header -column .xeito/log.sqlite "
  SELECT t.run_id, d.decision_type, d.value, round(d.confidence, 2) AS conf, d.actor, d.latency_ms
  FROM event_decision_made d JOIN xeito_term t ON t.ocel_id = d.ocel_id
  ORDER BY d.ocel_time DESC LIMIT 20;"
```

```bash
# The path a run took
sqlite3 -header -column .xeito/log.sqlite "
  SELECT t.run_id, e.from_state, e.to_state, e.event_name, e.actor
  FROM event_transition e JOIN xeito_term t ON t.ocel_id = e.ocel_id
  WHERE t.run_id NOT LIKE '%/esc' AND t.run_id NOT LIKE '%/intent'
  ORDER BY e.ocel_time DESC LIMIT 30;"
```

```bash
# Every shell command the agent ran
sqlite3 .xeito/log.sqlite "
  SELECT t.run_id, json_extract(r.args, '$.cmd')
  FROM event_effect_requested r JOIN xeito_term t ON t.ocel_id = r.ocel_id
  WHERE r.kind = 'bash' ORDER BY r.ocel_time DESC;"
```

```bash
# Runs with their machine and latest status (object attributes are versioned rows)
sqlite3 -header -column .xeito/log.sqlite "
  SELECT r.ocel_id, r.machine,
    (SELECT s.status FROM object_run s WHERE s.ocel_id = r.ocel_id AND s.status IS NOT NULL
     ORDER BY s.ocel_time DESC LIMIT 1) AS status
  FROM object_run r
  WHERE r.machine IS NOT NULL AND r.ocel_id NOT LIKE '%/esc' AND r.ocel_id NOT LIKE '%/intent'
  ORDER BY r.ocel_time DESC;"
```

Run ids tell you where a run sits:
- `ses-…/t3` is turn 3 of a session.
- `…/t3/e3/run` is a sub-run started by that turn's third effect.
- `…/esc` is the escalation between tiers behind one decision.

For process mining, [PM4Py](https://pm4py.fit.fraunhofer.de) reads the file directly:

```python
import pm4py
ocel = pm4py.read_ocel2_sqlite(".xeito/log.sqlite")
print(pm4py.ocel_get_object_types(ocel))
```

### Keeping the log small

Nothing is deleted automatically: the log is also what resume, `/why`, `/machines` and process mining read. List the sessions of a project and prune old ones explicitly:

```bash
mix xeito.log sessions --cwd ~/src/my-project
mix xeito.log prune --cwd ~/src/my-project --older-than 90 --keep 50           # dry run: shows what would go
mix xeito.log prune --cwd ~/src/my-project --older-than 90 --keep 50 --apply   # deletes, then compacts the file
```

- A session is `open` while a daemon holds it, `closed` after an idle close or a clean daemon stop, and `interrupted` if the daemon stopped abruptly (it is marked when the log next opens).
- `prune` deletes whole sessions (every run, event and relation under them), and only `closed` or `interrupted` ones. `--older-than DAYS` looks at last activity, and `--keep N` spares the N most recent sessions. With both options, a session must meet both conditions to be deleted.
- Runs outside any session (scripts, benchmarks) are kept.

The log stores each chat message once and refers to it afterwards, so a long conversation grows the log linearly ([05](docs/architecture/05-event-log-and-process-mining.md#storing-inputs-not-state)). Three more commands help with maintenance:

```bash
mix xeito.log stats --cwd ~/src/my-project     # where the bytes are, per table and event type
mix xeito.log verify --cwd ~/src/my-project    # replay every run and check it matches the log
mix xeito.log compact --cwd ~/src/my-project   # rewrite a log written by an older Xeito (stop the daemon first)
```

Conversations are plain JSON in the `xeito_message` table, one row per message, each pointing to its parent. Any SQLite tool can read them. For example, this prints the longest conversation a turn's run recorded:

```sql
-- sqlite3 .xeito/log.sqlite < this file; replace the run id (see `mix xeito.log sessions`)
WITH RECURSIVE c AS (
  SELECT * FROM xeito_message WHERE id = (
    SELECT r.head FROM xeito_term_chain r JOIN xeito_message m ON m.id = r.head
    WHERE r.ocel_id LIKE 'ses-abc123/t3:%' ORDER BY m.depth DESC LIMIT 1)
  UNION ALL
  SELECT m.* FROM xeito_message m JOIN c ON m.id = c.parent)
SELECT json_extract(json, '$.role'), substr(json_extract(json, '$.content'), 1, 120)
FROM c ORDER BY depth;
```

## 9. Evaluating deciders

Every decision type has labelled examples in `priv/decisions/<type>/examples.jsonl`, one JSON object per line:

```json
{"input": {"command": "ls -la"}, "label": "safe", "lang": "sh", "source": "synthetic"}
```

Compare tiers on them:

```bash
mix xeito.eval triage risk --deciders baseline,rules,small,large
mix xeito.eval intent --deciders small,large --epsilon 0.01          # cascade: how much can the small tier take?
mix xeito.eval triage --deciders large --predictions large --out /tmp/eval   # save verdicts as distillation data
mix xeito.eval intent --deciders large,openrouter --limit 20         # an off-box tier, on public data only
```

The report gives accuracy, coverage, macro-F1, calibration (ECE) and p50/p95 latency for each decider. It also includes the **gate test**, which checks whether a cheaper decider is good enough to replace the large one. With `--epsilon`, it adds the tuned cascade threshold. Off-box tiers are skipped for types that forbid them (Risk).

## 10. Extending

### A new machine

A machine is a module. Its states, transitions, guards and effects are data, so they're checked at compile time, drawn as diagrams and logged:

```elixir
defmodule MyApp.Machines.Release do
  use Xeito.Machine, version: "0.1.0"

  alias Xeito.Effect

  initial :checking

  state :checking, entry: :run_checks, timeout: 600_000 do
    on :ran, to: :tagging, guard: :passed?
    on :ran, to: :failed
  end

  state :tagging, entry: :tag, timeout: 60_000 do
    on :ran, to: :done, guard: :passed?
    on :ran, to: :failed
  end

  final :done
  final :failed

  def run_checks(ctx), do: [Effect.bash("mix format --check-formatted && mix test", cwd: ctx.cwd)]
  def tag(ctx), do: [Effect.bash("git tag v#{ctx.version}", cwd: ctx.cwd)]
  def passed?(_ctx, result), do: result.exit_status == 0
end
```

```bash
mix xeito.export MyApp.Machines.Release            # Mermaid diagram
mix xeito.export MyApp.Machines.Release --format scxml
```

To make it available as `/machine release`, add it to `Xeito.Session.Router.machines/0`. For routing from free-form requests, add a rule to `Xeito.Session.Router.route/2`. The routing tables are code for now; project-local machines in `.xeito/machines/` are planned.

### A new decision type

```elixir
defmodule MyApp.Decisions.ReviewNeeded do
  use Xeito.Decision, version: "1"

  instructions "Does this diff need a human code review before merging?"

  input :diff, max_bytes: 4_000, keep: :head

  value :no, "formatting, comments, docs or trivially safe changes"
  value :yes, "logic, security, data handling or public API changes"

  rule :docs_only?, then: :no

  deciders [:small, :large]
  min_confidence %{small: 0.8, large: 0.75}

  def docs_only?(%{diff: diff}), do: not String.contains?(diff, ".ex")
end
```

Use it inside a machine with `decide MyApp.Decisions.ReviewNeeded, input: :review_input`, and handle every value plus `:abstain`. The compiler checks that.

Rules run first and are always trusted. Models answer only what the rules don't cover, and a result below the confidence threshold escalates to the next tier. Add examples under `priv/decisions/review_needed/`, run `mix xeito.eval`, and keep a model tier only where the gate test says it earns its place.

### Scripting against the daemon

Any language that can write lines to a Unix socket can drive Xeito:

```bash
socat - UNIX-CONNECT:$HOME/.xeito/run/xeito.sock
{"id": 1, "cmd": "start", "cwd": "/home/me/src/my-project"}
{"id": 2, "cmd": "prompt", "session": "ses-…", "text": "which tests are slow?"}
```

Replies echo the request `id`. Events stream as `{"event": …, "session": …, "run": …, "attrs": {…}}`. The protocol reference is in `lib/xeito/api.ex`.

## 11. Ideas to get started

- **Start with questions.** Ask about code you know well, and check the transcript for the files it reads and the commands it runs. That's the fastest way to see what it can and can't do.
- **Let it fix one real failing test** per day. Then read the path in the log. Where did triage go wrong? Where did the chat run take a detour?
- **Label while you work.** Turn on `/break conf<0.7` for a week and answer unsure decisions with `/decide`. Each answer is a labelled example.
- **Write your `AGENTS.md`.** Short, concrete rules help more than long prose: test commands, forbidden directories, style.
- **Wrap a routine in a skill first.** A 10-line `SKILL.md` for "prepare a release" or "update the changelog" is the cheapest way to make a workflow repeatable. If it proves itself, turn it into a machine.
- **Turn repeated chats into machines.** If the log shows the same free-chat pattern again and again ("update the changelog", "bump the version and tag"), write it as a machine. It becomes faster, cheaper and auditable. This is how Xeito is meant to grow.
- **Tighten Risk for your repo.** Add a rule for a command you always approve (or always deny) and you'll see fewer reviews.
- **Compare tiers on your own data.** Export decisions with `--predictions`, relabel the wrong ones, and rerun the gate test with your small model.
- **Use step mode for teaching.** Walking through `fix_failing_test` with `/step` shows exactly how a statechart constrains a model.

## 12. Troubleshooting

| Symptom | Check |
|---|---|
| `no daemon at …/xeito.sock` | Is the daemon running? `systemctl --user status xeitod`, or start `mix xeito.daemon`. |
| every decision says `abstain` | No model tier is reachable. Check that the `XEITO_*` URLs are set *in the daemon's environment* and that the services answer. |
| the first answer takes seconds | The large model was unloaded (`XEITO_KEEP_ALIVE`) and has to be loaded again, which takes ~2.5 s on a 24 GB GPU. |
| text appears in one burst | Expected with Ollama: when tools are offered, it withholds streamed text until it knows the reply isn't a tool call ([bench 4](bench/4-harness.md)). |
| `busy` | A run is in progress. Wait, answer its review, or use `/continue` if it's paused. |
| a session seems gone | It closed after being idle. `--session <id>` with the same `--cwd` rebuilds it from the log. |
