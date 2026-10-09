# Testing Xeito locally

Everything here runs on a laptop without models: model calls in tests go to stubs. Only the benchmarks at the end need real model tiers.

## 1. Before every commit: `mix ci`

```bash
mix deps.get
mix ci
```

`mix ci` is the whole check, and CI runs the same command. On a push to `main`, CI leaves out mutation testing (`XEITO_MUTATE=off`), since it ran here before the commit; it runs nightly over every source (`XEITO_MUTATE=all`, also for a manual run here) and on pull requests:

| Step | What it catches |
|---|---|
| `format --check-formatted` | formatting, including Styler's rewrites. Fix with `mix format` |
| `compile --warnings-as-errors` | warnings and the compiler's type checker |
| `credo --strict` | design and complexity findings Styler cannot fix |
| `dialyzer` | type and spec errors. The first run builds the PLT and takes minutes; later runs take seconds |
| `test --cover` | the tests, then the CRAP gate on every function (§3) |
| `cmd mix xeito.mutate` | surviving mutants in the sources listed in `test/mutate.exs` (§4) |

It runs in the test environment and takes under a minute on a warm build. A red step stops it; the output above the error says which.

## 2. While working: tests first

Write the failing test, then the code, then refactor. Run as little as you need while you work:

```bash
mix test test/xeito/tui_test.exs          # one file
mix test test/xeito/tui_test.exs:240      # the test at that line
mix test --failed                         # what failed last time
mix test --seed 123456                    # the order of a run that failed (the seed is printed)
```

Where the tests are:
- `test/xeito/` holds unit tests: machine guards and actions, decisions, the TUI's `update/2`, the renderer and the log store. They are fast and mostly `async`.
- `test/xeito/harness_test.exs` drives whole sessions against a scripted model: a `Req.Test` stub speaking Ollama's API. It is the integration test of routing, the chat loop and the client API.
- `test/mix/tasks/` holds the mix tasks, run against real temporary workspaces and logs.
- `test/xeito/architecture_test.exs` checks the dependency rules between the client, the edges, the core and the machines on the compiled code ([08](architecture/08-tech-stack.md#code-style)).
- `test/support/` holds the helpers (`Xeito.Case`: `start_log!/0`, `scripted_runner/2`, `eventually/2`) and the CRAP and mutation tools.

Tests never touch your real configuration. Logs and workspaces go to temporary directories, and the TUI's preferences file is passed into `Xeito.Tui.new/1`.

## 3. Change risk: the CRAP gate

`mix test --cover` (in `mix ci`) scores every function: `complexity² × (1 − coverage)³ + complexity`. Above 6 the run fails and names the function, its complexity and coverage. A fully tested function may be as complex as 6; an untested one fails from complexity 3. The fix is a test first, then, if it is still over, a simpler function: a dispatch split by theme into dispatchers of at most six clauses, a lookup table where the cases differ only by name, or helpers for the branches of a long body. `XEITO_CRAP_SHOW="Mod.fun/2"` lists a function's lines that no test runs.

`test/crap_baseline.exs` lists older functions allowed above the maximum. It is empty and may only shrink. Never add new code to it. The run prints the five highest scores, which is worth a glance before a function gets there.

## 4. Mutation testing: would a test notice?

Coverage says a line ran. A mutant says whether any test would fail if the line were wrong. `mix xeito.mutate` changes one place at a time and reruns the tests against each change:
- it negates comparisons and moves them across the boundary;
- it swaps `and`/`or` and drops negations;
- it removes a clause, a list element or a `~w` word.

```bash
mix xeito.mutate                                    # the sources in test/mutate.exs (as mix ci does)
mix xeito.mutate lib/xeito/policy.ex                # one source, with its tests from test/mutate.exs
mix xeito.mutate lib/x.ex --test test/x_test.exs    # any source, against the tests you name
mix xeito.mutate lib/x.ex --test test/x_test.exs --lines 120-160
```

Each surviving mutant is printed with its place and the change, for example `lib/xeito/policy.ex:94  < → <=`, which means no test pins the limit's boundary. Add the test that kills it.

A mutant that cannot change behaviour (an *equivalent* mutant) usually marks dead or redundant code. Remove that code rather than leaving the mutant alive.

`test/mutate.exs` lists the sources held to zero survivors, each with the tests that cover it. An entry can limit a source to one section: `[tests: [...], section: "guards"]` mutates only the lines under the `# --- guards ---` comment. Each source runs only its own tests, so the list states truthfully what covers it. Add a source when its logic decides something that matters: security, limits, control flow, input handling.

## 5. The pre-commit hook

`scripts/check-crap.sh` runs the tests with the CRAP gate when Elixir files are staged. Without Elixir installed, it refuses the commit. To use it as your pre-commit hook:

```bash
ln -s ../../scripts/check-crap.sh .git/hooks/pre-commit
```

If you already have a pre-commit hook, call the script from it. Never commit with `--no-verify`. The hook checks less than `mix ci`, so run `mix ci` as well.

## 6. By hand: a throwaway daemon

`scripts/try-local.sh` starts a daemon on its own socket, with its own TUI preferences and a scratch workspace, and opens the TUI against it. Your real daemon, sessions and settings are untouched, and everything is removed when you quit (`XEITO_TRY_KEEP=1` keeps it).

```bash
scripts/try-local.sh                       # the TUI in an empty scratch workspace
scripts/try-local.sh --cwd ~/src/project   # in a real project (its session log goes to .xeito/ there)
scripts/try-local.sh --cwd .               # in the directory you are in
echo /help | scripts/try-local.sh --chat   # the line-mode client, scriptable: a quick smoke test
```

Model tiers are loaded as the service unit loads them, from `$XEITO_TIERS_ENV` or `~/.config/xeito/tiers.env` ([USAGE.md](../USAGE.md#model-tiers)); the chat model is the local tier. With `--no-models`, or without that file, everything but model calls works.

What to check after a TUI change:
- **Typing:** the cursor is a solid block while typing and blinks when idle. Long lines scroll.
- **The prompt line:** Up and Down recall earlier prompts and bring back a half-typed line. With no earlier prompts, they change nothing.
- **Commands:** `/help` and `/machines`; `/statusbar off`, `on` and `hide cpu` (the bar is one line); Ctrl-T toggles the bar. `/legend` shows the four risk dots in their colours. The status line starts with `○` when idle, spins while a turn runs, and shows `◆` on a yellow line during a review; its right end shows the workspace and branch. `/s` then Tab, Tab, Tab cycles `/send`, `/sessions`, `/skill:`; `/skills summarise a talk` lists a transcript skill first, and `/skill:transcri` then Tab completes it; `/machine c` then Tab gives `/machine chat`.
- **Runs without a model:** `/run mix test` in a project with tests. `/step` then `/run …` pauses before the result, and `/next` releases it. `/run sleep 30` then Esc halts it. `/run touch x.txt` then `/undo` removes `x.txt`, and `/redo` brings it back. During `/run sleep 5`, type `/run touch q.txt`: it shows as queued and runs when the sleep ends; with Esc during the sleep instead, it is held, and Enter on an empty line sends it. Steering (needs a chat model): ask for something that needs a review, type a line and press Ctrl-J, then approve; the model's next step follows the line.
- **Reviews (with a model):** ask for something that needs a risky command. Answer `y`, `n`, or with text saying what to do instead.
- **Layout:** resize the terminal; PgUp and PgDn scroll the transcript.
- **Quitting:** Ctrl-D quits.

## 7. With models: benchmarks and acceptance checks

These need tier endpoints in the environment and are run by hand, not by `mix ci`:
- `bench/scripts/*.exs` holds benchmarks and end-to-end runs (`mix run bench/scripts/p4_code_nav.exs WORKSPACE OUT.json`). Each script's header says what it needs.
- `bench/acceptance/` holds behavioural checks for benchmark tasks. They are copied into a benchmark workspace's `test/` after the run, so the model never sees them.
- `mix xeito.eval` evaluates deciders on their labelled examples ([USAGE.md §9](../USAGE.md#9-evaluating-deciders)).

The results and how they were measured go in `bench/*.md`, with the hardware class only.
