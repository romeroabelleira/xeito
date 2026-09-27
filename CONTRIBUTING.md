# Contributing to Xeito

Xeito is at the design and early implementation stage. See [docs/implementation-plan.md](docs/implementation-plan.md) for the current phase.

## Development setup

- Erlang/OTP and Elixir versions are pinned in [`.tool-versions`](.tool-versions). Install them with [mise](https://mise.jdx.dev) or asdf.
- Run the full local check before opening a pull request:

  ```bash
  mix deps.get
  mix ci          # format check, warnings as errors, credo --strict, tests
  mix dialyzer
  ```

- Local inference services (llama.cpp, Laya, Ollama) are optional for most work. [docs/architecture/09-reference-deployment.md](docs/architecture/09-reference-deployment.md) describes them, and `deploy/` holds example service units.

## Ground rules

- **New behaviour is a new machine, not a new feature** ([01 · Principles](docs/architecture/01-principles.md)).
- **Control flow is typed.** Model output that steers a run must be a typed decision ([03](docs/architecture/03-typed-decisions.md)).
- **No deployment specifics in the repository.** Do not commit host names, IP addresses, network layouts, exact hardware inventories of real machines, personal paths, credentials or employer context. Keep those in your own private configuration. Benchmarks are committed with the hardware *class* only.
- Add tests with every change. Keep the docs in `docs/architecture/` in sync when behaviour changes.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
