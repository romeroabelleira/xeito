# Skills

Skills for working on this repository, in the [Agent Skills](https://agentskills.io/specification) format: a directory with a `SKILL.md` (YAML frontmatter with `name` and `description`, then instructions), optionally with `references/`, `scripts/` and `assets/`.

| Skill | Use it for |
|---|---|
| [`elixir`](elixir/SKILL.md) | Functions, modules, data, pattern matching, error handling, tests; whether something needs a process at all |
| [`otp`](otp/SKILL.md) | Processes, supervision, `Task`, `Registry`, ETS, bottlenecks |
| [`skill-authoring`](skill-authoring/SKILL.md) | Writing, adapting or vendoring a skill under this convention |
| [`xeito-machine`](xeito-machine/SKILL.md) | Writing or changing a Xeito machine: states, effects, guards, typed decisions, delegation, versions, routing, tests |
| [`xeito-quality-gate`](xeito-quality-gate/SKILL.md) | Getting a change through the CRAP gate and mutation testing; killing surviving mutants |

## The convention

1. **Location: `.agents/skills/<name>/`.** The directory belongs to no single agent. Xeito reads it (`Xeito.Skills`), and so do other harnesses that read Agent Skills. A tool's own directory (`.claude/`, `.pi/`, …) is not used in this repository. An agent that does not read `.agents/skills/` by itself is pointed here by the project's instructions (`CLAUDE.md`).
2. **Written for any agent.** Say what to do ("read the file", "run the tests", "ask the user"), not which tool of which agent does it. No commands that only one agent or terminal setup has: no `claude -p`, no `unbuffer`, no paths into a tool's directory. Scripts a skill ships run through the shell like any other command, so xeito's `Risk` decision still applies to them.
3. **The project's rules win.** A skill does not bring its own checks, formatters or hooks: the check is `mix ci`, and the code style is in `CLAUDE.md` and `docs/architecture/08-tech-stack.md`. Where a skill and the project disagree, change the skill.
4. **Taken from elsewhere: kept recognisable.** Copy the skill unchanged with its license as `LICENSE`, and add an `ATTRIBUTION.md`: source, path, upstream commit and date, and a `## Changes` list. Change only what conflicts with this convention or this project, record each change with its reason, and put a one-line notice at the top of a changed `SKILL.md` (the Apache License asks for both).
5. **English, and nothing about any particular deployment**: no host names, personal paths or hardware. This repository is public (`CLAUDE.md`).

`test/xeito/repo_skills_test.exs` checks the parts a test can check: every skill loads, is named after its directory and has a description; no tool-specific commands; a vendored skill has its license, its upstream commit and its list of changes.
