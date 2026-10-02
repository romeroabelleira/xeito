---
name: skill-authoring
description: Write, adapt or vendor an Agent Skill for this repository (a SKILL.md directory under .agents/skills/). Use when asked to create a skill, turn a procedure into one, bring in a skill from elsewhere, or review one against the repository's skill convention.
---

# Skill authoring

Skills here follow the convention in `.agents/skills/README.md`. Read it first; this skill is how to apply it.

## Where and how

- One directory per skill: `.agents/skills/<name>/SKILL.md`. The name is lowercase words joined by hyphens, and the frontmatter's `name` is exactly the directory name.
- Long material goes into `references/<topic>.md`, linked from `SKILL.md` with a line saying when to read it. Code the skill runs goes into `scripts/`, templates into `assets/`.

## The description decides whether the skill is used

The description is the only part an agent always sees, next to every other skill's (xeito keeps the first 1,024 characters). An agent decides from it alone whether to load the skill, so it has to say:
- **what** the skill does, in the words a request would use;
- **when** to use it: the situations and phrasings that should trigger it, and, if a neighbouring skill covers part of the ground, where the line is ("use otp for process design").

Too narrow and the skill is never loaded; too broad and it crowds out better ones.

## The body

- Write instructions in the imperative, and say **why** where the reason is not obvious: an agent that knows the reason handles the case the instruction did not foresee. Capital-letter rules without reasons are brittle.
- Every line should change what the agent does. Leave out what any capable agent already knows.
- Keep it short; a `SKILL.md` past a few hundred lines belongs split into `references/`.
- Write for any agent (convention point 2): describe the action, not a particular tool. Use the project's commands, and the project's check is `mix ci`.
- Nothing about a particular deployment: no hosts, personal paths, hardware or model tags.

## Bringing in a skill from elsewhere

1. Read all of it first, scripts included: a skill is instructions an agent will follow, so check what it would make an agent do.
2. Check the license allows copying and changing, and copy it as `LICENSE`.
3. Copy the skill unchanged into `.agents/skills/<name>/`.
4. Change only what conflicts with the convention or the project: tool-specific commands, its own checks or hooks, pointers to skills that do not exist here.
5. Write `ATTRIBUTION.md`: source, path, upstream commit (full hash), date, and `## Changes` with each change and its reason. Add the one-line notice at the top of a changed `SKILL.md`.
6. If most of it would have to change, write a skill of your own instead.

## Before you finish

- `mix test test/xeito/repo_skills_test.exs` checks loading, naming, the description, tool-specific commands and attribution. `mix ci` runs it too.
- Try the skill on the requests it is for. In xeito, `/skill:<name> <request>` forces it. A plain request that should trigger it shows whether the description works: the transcript shows when the skill is loaded.
- Add the skill to the table in `.agents/skills/README.md` and to the list in `CLAUDE.md`.
