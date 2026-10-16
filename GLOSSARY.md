# Glossary

Xeito's terms, one line each, with the module that defines them. Read the module and its tests
for the details; `mix xeito.map` lists every module with its public functions.

## Runs and machines

- **machine**: a versioned statechart (states, events, guards, timeouts) declared with `use Xeito.Machine`. `Xeito.Machine`
- **run**: one execution of a machine, a process under `Xeito.RunSupervisor` whose every step is logged; resumable from the log. `Xeito.Run`
- **effect**: an action a machine asks for as data (`bash`, `read`, `write`, `edit`, `chat`, `machine`, `decide`); a runner performs it and its result comes back as an event. `Xeito.Effect`
- **runner**: what performs effects, after policy checks; the local one confines them to the workspace. `Xeito.Effects`
- **engine**: the pure statechart semantics: given a state and an event, the next state and the effects. `Xeito.Machine.Engine`
- **log**: the append-only OCEL 2.0 event log in SQLite, one per workspace; the single source of truth. `Xeito.Log`
- **recovery**: rebuilding a run from its logged events. `Xeito.Run.Recovery`
- **telemetry**: `:telemetry` events projected from what runs log. `Xeito.Telemetry`

## Decisions and tiers

- **decision type**: a question with a closed set of values, rules tried before any model, deciders and thresholds. `Xeito.Decision`
- **decision**: one answer to a decision type: a value with confidence, actor and provenance. `Xeito.Decision`
- **rule**: a deterministic answer in a decision type, tried first, confidence 1.0. `Xeito.Tiers.Rules`
- **tier**: a place on the escalation ladder, named by kind and place: `local_decision`, `remote_decision`, `local`, `remote`, `remote_frontier`. `Xeito.Tiers`
- **backend**: the API a tier speaks: `ollama`, `openrouter`, `system_one`. `Xeito.Backends`
- **System One model**: an encoder that returns a probability per option and generates no text (Laya, Jev). `Xeito.Backends.SystemOne`
- **decider**: the same ladder run in-process, for evaluation (`mix xeito.eval`). `Xeito.Decider`
- **escalation**: running a decision up the tiers until one is confident enough, as a logged machine. `Xeito.Escalation`
- **off-box**: every `remote*` tier: its input leaves the machine. `Xeito.Tiers`
- **policy**: which tiers a decision may use and under which limits (`remote`, `locality`, `max_usd_per_run`). `Xeito.Policy`
- **budget**: per-run spend and model-swap ledger, enforced by policy. `Xeito.Budget`
- **allowance**: what the OpenRouter key may still spend; a remote call is made only if its worst case fits. `Xeito.Allowance`
- **queue**: per-tier limit on concurrent calls. `Xeito.Tiers.Queue`
- **built-in decision types**: Intent (which machine), Risk (is a command safe), Skill (which skill), Triage (why a test fails), Done. `Xeito.Decisions`

## Sessions and chat

- **daemon** (`xeitod`): the long-running process that owns runs, logs and the client socket. `Xeito.Api`
- **session**: a workspace, a conversation and the runs started from it; clients talk to it. `Xeito.Session`
- **turn**: one user request and the run it starts (`<session>/t<n>`). `Xeito.Session`
- **chat machine**: the free agent loop (think, call tools, verify) for requests no other machine takes. `Xeito.Machines.Chat`
- **chat tier**: the tier chat runs on: `local`, or a remote one chosen with `/model`. `Xeito.Session.ChatModel`
- **chat client**: one streamed model call with tools, by the chat tier's backend. `Xeito.Chat`
- **message**: one entry of a conversation (Ollama's form, plus Xeito's bookkeeping keys); a **reply** is one model call's answer. `Xeito.Chat.Message`
- **context window**: what a request may hold; old tool output is elided, then old turns summarised or dropped. `Xeito.Chat.Window`
- **tools**: `read`, `write`, `edit`, `bash` (and `skill`), turned into effects. `Xeito.Tools`
- **shaping**: shortening tool output before the model reads it, readable back by its ref. `Xeito.Tools.Shape`
- **review**: a command Risk did not call safe waits for a human (`/approve`, `/deny`). `Xeito.Session.Allowed`
- **router**: picks the machine for a request from the Intent decision, by rules. `Xeito.Session.Router`
- **skill**: an Agent Skills directory (`SKILL.md`); the user's are shortlisted per turn and one is chosen. `Xeito.Skills`
- **outline, symbol**: a source file's modules and functions with line ranges, and one definition, for the `read` tool. `Xeito.Source`
- **repo map**: the compact map of a project put in the chat's system prompt. `Xeito.Source.RepoMap`
- **undo**: reverting the agent's workspace changes step by step (`/undo`, `/redo`). `Xeito.Undo`

## Clients and observability

- **client**: anything on the daemon's socket: the TUI, the line-mode chat, bridges. `Xeito.Client`
- **TUI**: the terminal client. `Xeito.Tui`
- **status bar**: the TUI's segments, counted from events and the monitor. `Xeito.Client.StatusBar`
- **monitor**: live readings of the host and the model services. `Xeito.Monitor`
- **events**: the live feed of what runs append to the log. `Xeito.Events`
- **step mode**: pausing a run before each result (`/step`, `/next`, `/break`). `Xeito.Run`
- **promotion candidates**: frequent free-chat requests that could become skills or machines. `Xeito.Promotion`

## Quality gates

- **CRAP**: change risk per function from complexity and coverage; at most 6. `Xeito.Crap` (`test/support`)
- **mutant**: a one-place change to a source; the tests must fail on it (`mix xeito.mutate`). `Xeito.Mutate` (`test/support`)
- **read cost**: the tokens an agent reads for a task (`mix xeito.context`). `Xeito.Source.ReadCost`
