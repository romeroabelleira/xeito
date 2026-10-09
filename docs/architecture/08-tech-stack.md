# 08 · Tech stack: is Elixir + Hologram a good fit?

[← Overview](00-overview.md) · Versions and facts verified 2026-09-27 (hex.pm, GitHub, project blogs).

## Short answer

**Elixir is an excellent fit for the core of Xeito, better than the JS/TS or Ruby alternatives, and for structural reasons, not taste.**
**Hologram is a good fit for one component, the local web inspector.** Adopt it there with a cheap exit route (Phoenix LiveView). Do not make it load-bearing.
**The TUI is the weakest spot of the BEAM ecosystem**, and it needs a deliberate choice. See below.

| Component | Choice | Confidence |
|---|---|---|
| Runtime, machines, supervision | Erlang/OTP 29 `gen_statem` + Elixir 1.20 | high |
| Model clients, structured output | `Req` directly for every tier (ReqLLM optional) | high |
| Local inference | **Out of process**: `laya-serve` `/v1/systemone` (CPU), `llama-server` (CPU) and Ollama (GPU) over HTTP | high |
| Embedding classifiers | Nx 1.0 + EXLA (CPU) + Bumblebee 0.8 (ModernBERT etc.) | medium-high |
| Event log | SQLite via `exqlite` (OCEL 2.0 layout) | high |
| Mining | PM4Py in a Python sidecar (batch) | high |
| Web inspector | **Hologram 0.11**, with a Phoenix LiveView 1.2 fallback | medium |
| TUI | **TermUI 1.0** (pure Elixir), with a spike against ExRatatui | medium-low |
| Packaging | `mix release` (daemon) + **Burrito** (CLI binary) | high |

## Why the BEAM fits this problem in particular

Xeito's core concepts map almost one-to-one onto OTP primitives. On other stacks, each of them would be a library, a framework or a hosted service:

| Xeito concept | OTP / Elixir primitive |
|---|---|
| Machine run | a `gen_statem` process, with timeouts, state-enter calls and postponed events built in |
| Isolation between runs | processes (no shared memory, crash one run and not the harness) |
| Crash policy per state | supervisors + restart strategies |
| Sub-machines, parallel regions | linked child processes, monitors |
| Step mode / breakpoints | `:sys.suspend/1`, `:sys.get_state/1`, postponed events |
| Live tracing | `:telemetry`, `:dbg`, `:sys.trace` · every process can be inspected at runtime |
| Hot machine upgrades | code/data reload without stopping running runs (runs stay pinned to their version) |
| Pattern-matching on typed decisions | `case` on tagged tuples/structs + Elixir 1.20's gradual type inference |
| Many concurrent model calls with timeouts | cheap processes + `Task.async_stream/3` with `timeout:` |

**Temporal-like durability, XState-like statecharts and LangGraph-like orchestration** would each be a dependency elsewhere. On the BEAM, they are ~1–2k lines on top of the standard library.

### Compared with the alternatives the user wants to leave

- **TypeScript/Node** (pi's stack). Its advantages are the best TUI libraries and the largest LLM SDK ecosystem. Its drawbacks are a single-threaded event loop, no process isolation, supervision that has to be built by hand, and an npm dependency surface that is a supply-chain liability.
- **Ruby on Rails** is built for request/response CRUD web apps. Long-lived stateful processes, timeouts and concurrency are not its strengths, and none of Xeito is a CRUD app.
- **Python** has the best ML ecosystem, and Xeito still uses it, for PM4Py only, in a sidecar. As the host for a long-running, concurrent, fault-tolerant harness, it is weaker than the BEAM.
- **Go/Rust** are both fine choices, but they give no statechart, supervision, hot reload or live introspection for free.

### Ecosystem status (Sept 2026)

- **Elixir 1.20** (June 2026) is a *gradually typed language*. It infers types without annotations and reports code that is guaranteed to fail. **OTP 29.1** is current.
- **ReqLLM 1.25** has 21 providers and `generate_object` for structured output. It is actively maintained, and Ash AI is moving to it. It was planned for the remote tier; in P3 the remote (Anthropic) and OpenRouter tiers were written directly on `Req` instead, like llama-server and Ollama, so that Xeito controls schemas, logprobs, provider routing and cost fields. ReqLLM remains an option for more providers.
- **Jido 2.3** (3.0 in beta) is an agent framework. **Xeito does not adopt it**: its value would be the agent loop, which Xeito deliberately replaces with machines. It is worth watching for tool/action conventions.
- **LangChain (Elixir) 0.14** is still 0.x. It is not needed.
- **instructor_ex** has not been updated since Feb 2025. **Avoid it.** Xeito's own decision compiler plus ReqLLM covers the need.
- **Nx/EXLA 1.0** (Sept 2026) and **Bumblebee 0.8** (with ModernBERT, Qwen3, Gemma3, SmolLM3) are enough for in-BEAM encoder classifiers on the CPU.
  EXLA has **no precompiled ROCm build**, so GPU work stays with Ollama/llama.cpp.
- **llama.cpp NIFs** (`llama_cpp_ex`) are young, single-maintainer and have no ROCm support, and a NIF crash takes down the VM. **Keep inference out of process.**
- **State-machine libraries.** No maintained *hierarchical* statechart library exists (`protean` was abandoned in 2022). `finitomata` is active, but it handles flat FSMs only. Xeito builds its own thin statechart layer on `gen_statem` ([02](02-state-machine-core.md)), and that layer is a candidate for a standalone library.

## Hologram: honest assessment

[Hologram](https://hologram.page) compiles Elixir component code to JavaScript that runs in the browser. You write client-side interactive UIs in Elixir, with no hand-written JS.

| | Facts |
|---|---|
| Version | **0.11.1** (2026-08-27). 0.11 requires Elixir ≥ 1.19 and OTP ≥ 28.1. There have been 28 releases; it is still pre-1.0. |
| Features | Components, actions and commands, an event system (keyboard, scroll, resize), middleware, **JS interop** since 0.8 (import npm packages, call Web APIs, JS Promises become Elixir Tasks). |
| Runtime coverage | Client-side Erlang runtime ~96%, Elixir stdlib readiness ~87%. Some functions still don't run in the browser. |
| Adoption | ~8k Hex downloads, 2 dependent packages, ~1.5k stars. It claims production users. |
| Bus factor | **Effectively one.** The maintainer has ~13.4k of ~13.7k commits. Funded by Curiosum plus EEF milestone grants. |
| Roadmap | Local-first sync, auth and forms, a testing toolkit, a standalone mode. |

**For comparison, Phoenix LiveView 1.2.12** (Sept 2026) has ~45M downloads, 700+ dependent packages, and is maintained by the core team. It is the conservative choice.

### Why Hologram still fits the inspector

The inspector is **local, single-user and read-mostly**. Its heavy part is *client-side* interaction: scrubbing a timeline, stepping through thousands of events, filtering, zooming a process map.
LiveView would round-trip each of those interactions to the server. That works fine on localhost, but it pushes the design toward server state for pure UI concerns.
Hologram runs that logic in the browser *in Elixir*, which is exactly the "no JS/TS" goal. JS interop covers the one thing Xeito cannot sensibly write itself: a graph layout library (e.g. ELK.js or Cytoscape) for process maps.

The risks are real (bus factor, pre-1.0 churn, stdlib gaps) and they are **contained**:

- The inspector is a *read model* over the event log. Nothing in the core depends on it.
- A rewrite in LiveView would cost ~2–4 weeks, not a re-architecture.
- Pinning versions means churn happens only when Xeito chooses it.

### Decision procedure

Phase P6 opens with a one-week **spike**. Build the *machine view* (the declared statechart with live state highlighting and transition counts) in both Hologram and LiveView, then score each on:

1. Lines of Elixir, and whether any JS was needed beyond the graph library.
2. Smoothness when stepping through a 5k-event run from a second machine over an SSH tunnel.
3. Whether a Hologram stdlib gap blocked anything.
4. How long a fresh `mix deps.update` takes to break it (a churn proxy).

The default is Hologram, unless a gap in point 3 blocks it or point 2 is clearly worse. Record the decision as an ADR (architecture decision record).

## The TUI: the weakest link

pi's TUI (differential rendering, editor, diff views) is excellent, and **nothing on the BEAM matches it yet**.

| Option | Status | Notes |
|---|---|---|
| **TermUI 1.0** | Released 2026-08, ~5k downloads | Pure Elixir, Elm architecture (inspired by BubbleTea). No NIF. **Default.** |
| **ExRatatui 0.16** | Active, ~1k/month | Rust ratatui via Rustler NIF. Most capable widgets, but a NIF crash would take down the TUI process. |
| **Owl 0.13** | Mature CLI toolkit | Prompts, tables and live blocks, not full-screen. Good for `xeito run …` non-interactive output. |
| Ratatouille | Last release 2020 | Dead. |
| **pi itself** | TS, MIT, v0.87 | pi's RPC mode is *external process drives pi*, so pi keeps its own agent loop. A pi extension could expose Xeito machines as commands and tools, but it cannot replace pi's loop. |

**Recommendation.** Put the TUI in a **separate OS process from the daemon**: `xeito` is a Burrito binary that connects to `xeitod`, a `mix release` running as a systemd user service, via Erlang distribution over a Unix socket or localhost.
A TUI library crash, or a NIF crash if ExRatatui wins, then never kills a run, and the TUI library can be swapped cheaply.
Start with **TermUI**. Spike ExRatatui in P4 if TermUI's editor or diff widgets fall short.
Offer a **pi bridge extension** (a small TS file, the only JS in the project, and optional) that lets pi users call Xeito machines from inside pi. It is cheap reach into the pi community, not a dependency.

**Outcome (P4).**
- **TermUI is adopted.** Its Elm runtime forwards other processes' messages to the root's `handle_info/2`, so daemon events need no glue. Its text input and styling cover the prompt, transcript and status line. The ExRatatui spike was not needed.
- **The client talks JSON Lines** over the daemon's Unix socket rather than Erlang distribution ([07](07-harness-frontend.md#as-implemented-p4)).
- **Caveat:** TermUI pulls in `mdex`, whose native part is a precompiled Rust NIF fetched at build time. It is loaded only in the TUI process, since `term_ui` is a `runtime: false` dependency the daemon never starts. The P8 Burrito packaging should split the TUI into its own binary.

## What stays outside Elixir, and why

| Component | Language | Reason |
|---|---|---|
| `laya-serve` (System One decider) | Python + PyTorch (CPU), upstream container | Jev-compatible API, ~60–90 ms per warm decision on the CPU. Called over HTTP like every other tier. An ONNX export via Ortex in-BEAM is possible later, but Ortex is barely maintained, so out of process is safer. |
| `llama-server` | C++ (llama.cpp) | The fastest CPU inference with AVX-512, and grammar/JSON-schema constraints. Out of process for isolation. |
| Ollama | Go | Mature local serving of the large models. |
| PM4Py sidecar | Python (`uv`) | The reference process-mining implementation. Batch jobs only. |
| Graph layout in the inspector | JS library via Hologram interop | Graph layout is a solved problem, and Xeito does not write it itself. |
| Optional pi bridge | TypeScript | Only because pi is TypeScript. |

## Versions to pin in P0

```
erlang 29.1.1
elixir 1.20.4-otp-29
# deps (initial): req, req_llm ~> 1.25, exqlite, jason, telemetry,
# phoenix_pubsub, term_ui ~> 1.0, burrito ~> 1.6,
# nx ~> 1.0, exla ~> 1.0, bumblebee ~> 0.8   (P7)
# hologram ~> 0.11 | phoenix_live_view ~> 1.2 (P6, after spike)
```

## Code style

Style is settled by tools, not by review:
- **`mix format`** with the [Styler](https://hexdocs.pm/styler) plugin (`.formatter.exs`). Styler goes beyond layout: it orders module directives, lifts aliases, straightens pipes and rewrites some constructs. It deliberately has no per-rule configuration, which is the point.
- **Credo** (`.credo.exs`, run with `--strict`) keeps the checks Styler cannot fix: warnings, design and complexity. The 28 Credo checks that Styler already rewrites are disabled, a list taken from Styler's "Styler & Credo" docs.
- **One command:** `mix ci` runs the format check, compiling with warnings as errors (which includes the type checker), Credo, Dialyzer, the tests with coverage and mutation testing. CI runs exactly that, except that a push to `main` skips mutation testing (`XEITO_MUTATE=off`: it ran before the commit, locally), which runs nightly over every source (`XEITO_MUTATE=all`) and on pull requests over what they change. A newer run replaces one still running for the same event and branch.
- **Change risk:** the tests run with a CRAP gate (Change Risk Anti-Patterns: `complexity² × (1 − coverage)³ + complexity` per function; `test/support/xeito/crap.ex`). The maximum is 6 (the metric's authors proposed 30; lowered on 2026-10-02): a fully tested function may be as complex as 6, while an untested one fails from complexity 3. Every function with logic needs tests, and anything more complex is split, however well tested.
  - Existing functions above it are listed in `test/crap_baseline.exs`. Each may not get worse, and its entry must go once the function is at or under the maximum. The list only shrinks; it has been empty since 2026-10-01.
  - The pre-commit hook (`scripts/check-crap.sh`) and CI enforce the gate.
- **Architecture rules:** `test/xeito/architecture_test.exs` reads the calls each compiled module of `lib/` makes and checks three rules: the TUI and line client reach the daemon only through its socket, apart from a short list of library calls, each with its reason (ADR 007); the core never calls the edges (clients, API, sessions, the application, mix tasks); machines and their engine perform no effects themselves, so runs stay replayable (ADR 005). A new dependency that breaks one fails `mix test`. Change the rule only together with the ADR it comes from.
- **Mutation testing:** coverage says a line ran, not that a test would fail if it were wrong. `mix xeito.mutate` (`test/support/xeito/mutate.ex`) changes one place at a time, loads the mutant over the real module and reruns the tests in the same VM: a mutant they miss *survives*. Mutations:
  - comparisons negated and moved across the boundary;
  - boolean operators swapped, negations dropped, `in` negated, `if` and `unless` swapped, `+` and `-` swapped;
  - a clause removed from a multi-clause function or from a `case`, `cond` or `fn`;
  - an element removed from a literal list, a word from a `~w` sigil, including constants in module attributes.
  
  The sources in `test/mutate.exs` are held to zero survivors; `mix ci` runs them (seconds, not minutes):
  - Risk, Policy, Budget, and the chat machine's guards (an entry can name one `# --- section ---` of a file).
  - Each source runs only the tests listed for it, so the list says truthfully what covers it.
  - A mutant that cannot change behaviour (an *equivalent* mutant) usually marks dead code: remove the code rather than excuse the mutant.
  
  Other files can be checked by hand: `mix xeito.mutate PATH`.

Styler is pinned to a minor version (`~> 1.12.2`), so new rewrites arrive only through a deliberate upgrade. On an upgrade, run `mix format` across the project, read the diff, and update the disabled list in `.credo.exs` from Styler's docs. A few Styler rewrites can change behaviour (its README lists them), so the tests must pass on the rewritten code before it is committed.
