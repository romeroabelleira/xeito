# Attribution

From [georgeguimaraes/elixir-agent-tools](https://github.com/georgeguimaraes/elixir-agent-tools), path `plugins/elixir-dev/skills/elixir`, upstream commit `ac3a5a1661a087158b39d5eb742b3c25fe3c7b44`, taken on 2026-10-02. Licensed under the Apache License 2.0; see `LICENSE`.

## Changes

- **Verification:** runs the project's own check (`mix ci` here) instead of prefixing every `mix` command with `unbuffer`, and no longer reports a missing `unbuffer` as a prerequisite. `unbuffer` runs a command under a pseudo-terminal, for colours and line-by-line output. Mix's output already streams through a pipe, agents receive a command's output only once it has finished, and colour codes are noise that costs tokens. Tool-specific wrappers are also against this repository's skill convention (`../README.md`).
- A notice at the top of `SKILL.md` points here.
