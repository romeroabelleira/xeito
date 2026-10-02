---
name: xeito-quality-gate
description: Get a change in this repository through its quality gates, the CRAP score per function (max 6) and mutation testing (mix xeito.mutate). Use when mix ci or the pre-commit hook rejects a function as too risky, when a mutant survives, when adding a source to test/mutate.exs, or when deciding how to test new code so that it passes both.
---

# Quality gates

`mix ci` must pass before every commit: format, warnings as errors, Credo, Dialyzer, the tests with the CRAP gate, and mutation testing. The pre-commit hook (`scripts/check-crap.sh`) runs the CRAP gate again. Never get around a gate (no `--no-verify`, no baseline entry, no skipped test): a gate that fails is pointing at real risk. `docs/testing.md` describes the whole local procedure.

## CRAP: complexity times untested-ness

Each function scores `complexity² × (1 − coverage)³ + complexity` (`test/support/xeito/crap.ex`). Over 6, the run fails and names the function, its complexity and its coverage. Complexity counts 1, plus one for each further function clause, `if`/`unless`, `&&`/`||`/`and`/`or`, each `case`/`cond`/`fn` clause after the first, each `<-` of a `with` and each `else` clause after the first.

What the score tells you:
- **Coverage low:** the function does something no test exercises. Untested, complexity 3 already fails (2 scores exactly 6). Write the tests first; that is the fix most of the time. `XEITO_CRAP_SHOW="Mod.fun/2" mix test --cover` lists the lines no test runs.
- **Complexity over 6, even when covered:** split it, after its tests are in place.
  - A dispatch on a name or kind becomes themed dispatchers of at most six clauses each (`Session.command/3` hands commands to `start_command`, `turn_command`, `info_command`, `debug_command`), or a lookup table where the cases differ only by name (the TUI's key table).
  - A process callback (`handle_event/4`, `handle_info/2`) dispatches on the kind of message to small functions.
  - The branches of a long body become helpers; every extra `if`, `&&` or guard `and` counts.
- Code that only wires processes, terminals or sockets (a mix task's `run/1`, a TUI's `init/1`) scores high when untested. Move its logic into pure functions you can test, and keep the wiring thin.

`test/crap_baseline.exs` held older debt and is empty; it may only shrink. Never add a function to it.

## Mutation testing: would a test notice?

`mix xeito.mutate` changes one place at a time and reruns the tests. A mutant the tests miss **survives**: behaviour that no test pins down. The sources listed in `test/mutate.exs` (security and decision logic first) must have no survivors, each against the tests listed for it. Check other code by hand: `mix xeito.mutate lib/x.ex --test test/x_test.exs`, optionally `--lines 10-40`.

What a survivor usually means:

| Mutation | What no test checks |
|---|---|
| `>` → `>=` (boundary) | the exact limit: off-by-one |
| `==` → `!=`, `>` → `<=` (negation) | the condition itself, in one direction or both |
| `and` ↔ `or` | the cases where only one side holds |
| `if` ↔ `unless`, `not x` → `x` | the branch the condition chooses |
| clause removed (function, `case`, `cond`, `fn`) | the input that clause exists for |
| list element or `~w` word removed | one entry of a list: an allowlist, a denylist, a set of separators |
| `+` ↔ `-` | the arithmetic |

How to kill one:
1. Find the **scenario** the code exists for: the input and the outcome someone relies on. Write that test, named after the behaviour, not after the mutant. A test that pins a scenario survives refactoring; one that only kills a mutant does not.
2. If there is no such scenario, the code may be unnecessary: an **equivalent mutant** (no input can tell the difference) marks dead or redundant code. Remove it rather than excuse it.
3. Lists that are tuning data (stopwords, heuristics) need not have a test per entry. Lists that decide safety (allowlists, denylists, separators) do: changing what counts as safe should change a test.

## Adding a source to the mutation gate

Add an entry to `test/mutate.exs`: `"lib/x.ex" => ["test/x_test.exs"]`, or `[tests: […], section: "guards"]` for the lines under a `# --- guards ---` comment. List only the tests that should cover it; each source runs against its own tests, so the entry states truthfully what covers it. Run `mix xeito.mutate lib/x.ex`, kill the survivors, then run `mix ci`.
