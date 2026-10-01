# Xeito: notes for agents

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

Run `mix format` after editing. It includes Styler, which also rewrites code (aliases, pipes, directive order), so don't hand-format against it. `mix ci` is the check to pass before committing: format, warnings as errors, `credo --strict`, and tests with the CRAP gate.

Work test-first: write a failing unit test, then the code, then refactor. Every function must stay at or below a CRAP score of 30, computed from complexity and coverage (`test/support/xeito/crap.ex`). Functions listed in `test/crap_baseline.exs` are older debt: they may not get worse, and an entry must be removed once its function is at or under 30. Never add new code to the baseline. The pre-commit hook (`scripts/check-crap.sh`) refuses a commit that fails the gate. See [docs/architecture/08-tech-stack.md](docs/architecture/08-tech-stack.md#code-style).
