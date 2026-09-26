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
