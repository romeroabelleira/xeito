# Xeito: notes for agents

These are the project's instructions for any coding agent: Xeito itself reads this file into its chat turns, and so do other harnesses; Claude Code reads it through `CLAUDE.md`, which only imports it.

## Hard rule: this repository is public

Never commit deployment- or operator-specific details. This covers:

- host names and SSH aliases
- IP addresses, LAN and VPN details, bind addresses of real machines
- exact hardware inventories of real machines
- personal paths and usernames
- local model tags and custom Modelfiles
- employer or work context
- personal funding or business plans

Write docs against a generic *reference workstation* ([docs/architecture/09-reference-deployment.md](docs/architecture/09-reference-deployment.md)) and describe hardware by class.
Operator-specific material belongs in a private companion repository, which is never pushed here.
Guard hooks (pre-commit, commit-msg, pre-push) scan for such content. Do not bypass them with `--no-verify`.

## Code style

Run `mix format` after editing. It includes Styler, which also rewrites code (aliases, pipes, directive order), so don't hand-format against it. `mix ci` is the check to pass before committing: format, warnings as errors, `credo --strict`, Dialyzer, tests with the CRAP gate, and mutation testing.

Work test-first: write a failing unit test, then the code, then refactor. Every function must stay at or below a CRAP score of 6, computed from complexity and coverage (`test/support/xeito/crap.ex`): fully tested, a function may be as complex as 6; untested, it fails from complexity 3. Functions listed in `test/crap_baseline.exs` are older debt: they may not get worse, and an entry must be removed once its function is at or under 6. Never add new code to the baseline. The pre-commit hook (`scripts/check-crap.sh`) refuses a commit that fails the gate. Sources listed in `test/mutate.exs` must have no surviving mutants (`mix xeito.mutate`, part of `mix ci`): when one survives, add the test that kills it. See [docs/architecture/08-tech-stack.md](docs/architecture/08-tech-stack.md#code-style), and [docs/testing.md](docs/testing.md) for the whole local procedure; `scripts/try-local.sh` tries a change by hand against a throwaway daemon.

## Skills

Skills for working on this repository are in `.agents/skills/`, under the convention in [.agents/skills/README.md](.agents/skills/README.md). Not every agent loads that directory by itself, so read the matching `SKILL.md` before the task:

- [`elixir`](.agents/skills/elixir/SKILL.md): writing or refactoring Elixir: modules, data, pattern matching, error handling, tests, and whether something needs a process at all.
- [`otp`](.agents/skills/otp/SKILL.md): processes, supervision, `Task`, `Registry`, ETS, bottlenecks.
- [`skill-authoring`](.agents/skills/skill-authoring/SKILL.md): writing, adapting or vendoring a skill.
- [`xeito-machine`](.agents/skills/xeito-machine/SKILL.md): writing or changing a machine: states, effects, guards, typed decisions, delegation, versions, routing, tests.
- [`xeito-quality-gate`](.agents/skills/xeito-quality-gate/SKILL.md): the CRAP gate and mutation testing, and how to kill a surviving mutant.

Where a skill and this file disagree, this file wins. Don't add skills under `.claude/` or another tool's directory.

