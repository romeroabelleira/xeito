# Xeito

> A minimalist agent harness that puts language models inside a state-machine corset,
> records every transition, and mines its own runs to get better.

Xeito keeps the front end small and plain, in the style of [pi](https://pi.dev): a terminal, a handful of tools, no ceremony.
The back end rests on three ideas:

1. **State machines first.** Every task is modelled as a statechart before any model is called.
   A model call can only choose among the transitions that are legal in the current state.
2. **Typed decisions.** A model never "decides" in free text.
   Each decision returns a value of a closed, schema-validated type, together with a confidence score, and it can be cached, replayed and evaluated.
3. **Process mining as the meta state machine.** Every transition is written to an object-centric event log (OCEL 2.0).
   Mining those logs shows the process that *actually* happened. Conformance checking compares it with the declared machine, and the findings become reviewed changes to the machines.

The reference deployment runs on a single workstation. Rules and a local GPU model make typed decisions, and delegation between tiers (small decision models, the local model, opt-in hosted models) is itself a state machine.

## Documents

| Doc | What it is |
|---|---|
| [USAGE.md](USAGE.md) | How to set up, run and extend Xeito, with examples |
| [docs/design.md](docs/design.md) | One-page design doc |
| [docs/architecture/00-overview.md](docs/architecture/00-overview.md) | Architecture draft (overview + one file per section) |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Step-by-step implementation plan with exit criteria |
| [docs/testing.md](docs/testing.md) | Testing locally: `mix ci`, the CRAP gate, mutation testing, trying changes by hand |
| [docs/architecture/references.md](docs/architecture/references.md) | Prior art and bibliography |

## Status

Pre-release, in active development (September 2026), in Elixir/OTP ([08-tech-stack](docs/architecture/08-tech-stack.md)).
- **Done:**
  - the state-machine core and OCEL log (P1)
  - typed decisions on CPU and GPU tiers, with evaluation (P2)
  - escalation as a state machine, with policy and budgets (P3, P3b)
- **In progress:** the harness (P4): a daemon, a TUI and a free chat machine.
- See the [implementation plan](docs/implementation-plan.md) and the [benchmarks](bench/).

```bash
mix xeito.daemon            # runs, logs, and the client socket (tier endpoints from the environment)
mix xeito.tui --cwd PROJECT # terminal UI on a session in PROJECT (or: mix xeito.chat, line mode)
```

Tier endpoints are configured through `XEITO_*` environment variables. See [USAGE.md](USAGE.md) for setup, examples and ideas.

*Xeito* is Galician for "knack" or "the right way of doing something".
