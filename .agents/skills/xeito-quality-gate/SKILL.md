---
name: xeito-quality-gate
description: Get a change in this repository through its quality gates, the CRAP score per function (max 30) and mutation testing (mix xeito.mutate). Use when mix ci or the pre-commit hook rejects a function as too risky, when a mutant survives, when adding a source to test/mutate.exs, or when deciding how to test new code so that it passes both.
---

# Quality gates

`mix ci` must pass before every commit: format, warnings as errors, Credo, Dialyzer, the tests with the CRAP gate, and mutation testing. The pre-commit hook (`scripts/check-crap.sh`) runs the CRAP gate again. Never get around a gate (no `--no-verify`, no baseline entry, no skipped test): a gate that fails is pointing at real risk. `docs/testing.md` describes the whole local procedure.

## CRAP: complexity times untested-ness

Each function scores `complexity² × (1 − coverage)³ + complexity` (`test/support/xeito/crap.ex`). Over 30, the run fails and names the function, its complexity and its coverage. Complexity counts 1, plus one for each further function clause, `if`/`unless`, `&&`/`||`/`and`/`or`, each `case`/`cond`/`fn` clause after the first, each `<-` of a `with` and each `else` clause after the first.

What the score tells you:
- **Coverage low:** the function does something no test exercises. Untested, complexity 5 is already 30. Write the tests first; that is the fix most of the time.
- **Complexity high even when covered** (over 30 at full coverage): split it. The usual shape is a dispatch, one small function per case (`Effects.Local.run/2` hands each effect kind to its own function); a long `case` in a body becomes function clauses or helpers.
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
