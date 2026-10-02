# Attribution

From [georgeguimaraes/elixir-agent-tools](https://github.com/georgeguimaraes/elixir-agent-tools), path `plugins/elixir-dev/skills/otp`, upstream commit `ac3a5a1661a087158b39d5eb742b3c25fe3c7b44`, taken on 2026-10-02. Licensed under the Apache License 2.0; see `LICENSE`.

## Changes

- **Description:** no longer sends durable background jobs to an `oban` skill, which this repository does not have (xeito delegates work through its own logged state machines). The body's notes on Oban and Broadway stay, as background.
- A notice at the top of `SKILL.md` points here.
