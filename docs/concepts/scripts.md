# Concept · Scripts: busywork the model hands off, logged and promotable

Status: concept, 2026-10-09. Not planned yet; the last section proposes where it fits.

## The question

pi added built-in MCP and **Codemode** on 2026-09-29 ([Earendil's post](https://earendil.com/posts/you-said-no-mcp/); [codemode docs](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/codemode.md); [MCP docs](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/mcp.md)). Instead of one tool call per model turn, the model writes a JavaScript script that calls many tools, filters their results and returns only what matters. The post's example: list 167 open issues through an MCP server, fetch each one's comments, have a classifier rate each thread for frustration (four at a time), store the verdicts, and return a summary. The model wrote the program once; the busywork cost no model tokens per issue.

That is ad-hoc delegation of busywork, and it is very good at it. How does Xeito, whose premise is that control flow lives in declared state machines, answer it?

**Short answer.** Do the same thing, as an effect like every other, and then do what pi cannot: log every call the script makes, gate each one, replay it, let `/undo` reverse it, use typed decisions instead of ad-hoc questions, and mine the scripts that recur into skills and machines that no longer need a model. In pi a script is disposable. In Xeito it is the first draft of a machine.

## What pi's Codemode is

| Part | How it works |
|---|---|
| Script | JavaScript, the body of an async function, in a QuickJS sandbox on the harness side: no file system, network, Node APIs or timers. 256 MB, an optional deadline, output capped (10k tokens by default; the rest goes to a temp file). |
| Tools | Every tool is `tools.<name>(args)`: `bash` resolves to `{output, exit_code, …}` with up to 1 MiB of output, MCP tools to their full `CallToolResult`. Calls are real; those made before a failure are not undone. |
| Discovery | Declarations of the listed tools share a 3000-token budget in the tool description. The rest (all MCP tools, by default) are found from scripts with `searchTools()` (BM25), `describeTool()`, `describeNamespace()`. |
| Non-LLM models | `models.classify()` answers typed questions (`choice`, `score`, `bool`, each with criteria) about a JSON state, with probabilities and a confidence, four calls at a time; `models.generateImages()`. Chat models cannot be run from scripts. |
| State | `store(key, value)` / `load(key)`: small JSON (1 MiB in all), written to the session transcript when a script succeeds, so branches see their own values. |
| MCP exposure | Per server and per tool: `codemode` (default: callable from scripts only), `deferred` (loaded by `tool_search`), `direct` (declared to the model), `hidden`. |
| Safety | Tools run with pi's own permissions. Every call from a script goes through the tool pipeline with its parent call's id, so a permission extension can gate it; MCP annotations (`readOnlyHint`, `destructiveHint`, …) are passed on for such extensions to use. |

Two things stand out. Classification with typed questions and calibrated probabilities is Xeito's typed decision, asked ad hoc from a script. And the script, the per-item verdicts and the reasons for them live in a transcript, where nothing learns from them.

## Why Xeito wants this too

The case is stronger for Xeito than for pi. pi usually drives a frontier model; Xeito drives a local one, where each model turn costs seconds of prompt processing ([bench 4](../../bench/4-harness.md)). Turning 170 tool turns into one script turn is worth more on a 27B model on one GPU than on a hosted frontier model. And a local model is the one most likely to lose its way over 170 turns.

The free chat machine already sees the pattern: requests that need the same few commands over many files, tests or log entries, done one call per step.

## The design

### 1. A `script` effect

A new tool, `script`, whose argument is a program in Elixir (section 7). The chat machine's `executing` state runs it like any tool call, as one effect. Inside, the program reaches the outside only through functions the runner provides:

| Function | What it becomes |
|---|---|
| `read(path)`, `bash(command)`, `write(path, text)`, `edit(path, old, new)`, `mcp(server, tool, args)` | **an effect of its own**, a child of the script's effect, logged as the chat machine's tool calls are, and shaped by `Xeito.Tools.Shape` only for what the script returns |
| `decide(Type, input)` | a typed decision of a registered type (`Xeito.Decision`), through the escalation ladder: rules first, then the cheapest tier that is sure enough |
| `classify(questions, state)` | an **ad-hoc decision**: pi's `choice` / `score` / `bool` questions become a decision type built for the call, decided by the `local_decision` tier (a System One model, the same kind of model as pi's Jev) or the `local` tier |
| `remember(object, attrs)` | an object in the run's OCEL log (see 4) |
| `text(value)`, and the script's last value | the script's output, the only part the model reads |

The script's output goes back to the model as the tool result. Inner results never reach the context unless the script returns them.

### 2. Every inner call passes the same gates

pi leaves gating to extensions. In Xeito it is the effect runner's job, so a script cannot get round it:

- **Risk** decides on every inner `bash` call, rules first, exactly as for a direct call. A command allowed with `/approve session` or `always` stays allowed inside scripts.
- **What a review means inside a script.** The first version does not pause a script for a human: a call that Risk sends to review rejects with an error that says so, and the script decides what to do (usually return it; the model then makes the call directly, where the review happens as today). Pausing a script mid-run for a review is possible later, since the runner already holds results in step mode.
- **Policy and budgets** apply per call: `:local_only` inputs never reach an off-box tier from a script, and a script's model calls count against the run's budget.
- **Undo**: a script's workspace changes are one step for `/undo`, labelled by the script, with each inner write recorded. pi's "calls before a failure are not undone" becomes "the whole script can be undone".
- **Halt and timeouts** stop the script and its running commands, as for `bash` (`Xeito.Effects.OsCommand`).
- **Step mode** can pause before each inner result, so a script can be debugged call by call.

### 3. Replay

A script is a program plus the results of the calls it made. The log holds both, so a replay runs the same program and feeds it the logged results instead of calling anything. That needs a deterministic sandbox: no clock, no randomness the log does not supply (`now()` and `random()` come from the runner and are logged), and no I/O other than the provided functions. With that, a script run is as replayable as a machine run, and a desync shows exactly which call came back differently.

### 4. Results as objects in the log, not a key-value store

pi's `store()` keeps up to 1 MiB of JSON in the transcript. Xeito's log is object-centric: the 167 issues of the example are naturally **objects** (`issue`, with attributes), and each verdict is a decision event related to its object. `remember(object, attrs)` writes them there. The next question ("which of those frustrated threads mention billing?") is a query on the log (`mix xeito.log`, and later a `query` function for scripts), not a refetch. And every verdict a classifier gave is a labelled example for later evaluation and fine-tuning (P7), which in pi it never becomes.

### 5. From ad hoc to promoted

This is where Xeito competes rather than imitates. Scripts are logged with the request that led to them, their inner call sequence, their decisions and their outcome. Mining (P5) clusters them:

1. **The same ad-hoc question asked again and again** (`classify` with the same criteria) becomes a candidate **decision type**: named, with examples from the logged verdicts, evaluated with `mix xeito.eval`, and on to rules or a fine-tuned classifier as any decision graduates ([03](../architecture/03-typed-decisions.md)).
2. **The same script, give or take its parameters**, becomes a candidate for the **`script` promotion target** planned for P7: a saved, parameterised script, reviewed by a human, that a skill or a command runs without asking the model to write it again.
3. **A script whose shape is stable** (fetch, decide per item, act per verdict) becomes a candidate **machine**: its phases become states, its decisions typed decisions, its error handling transitions. The determinism budget rises with each one.

Codemode makes the model a quick programmer of throwaway glue. Xeito makes it the programmer of first drafts, and the log the reviewer that decides which drafts are kept.

### 6. MCP, with pi's exposure model

The MCP client planned for P9 ("tools of configured MCP servers become effects, logged and gated by Risk and policy like `bash`") takes pi's exposure levels, which solve a real problem: dozens of MCP tools in the prompt cost context on every turn.

- `script` (the default, as in pi): callable from scripts only, found with `searchTools()`, which reuses the BM25 index of skills (`Xeito.Skills.Index`, P4f).
- `deferred`, `direct`, `hidden`: as in pi.
- **Annotations feed Risk's rules**: a tool marked read-only and not open-world is safe by rule; one marked destructive goes to review; anything unmarked is judged like an unknown command. Servers are trusted per workspace, as `.xeito/allowed.json` already trusts commands.
- **Data locality**: a server marked open-world (it reaches the internet) is an off-box destination for policy. A `:local_only` input cannot be sent to it from a script either.

### 7. The language and the sandbox

**Scripts are Elixir**, evaluated with [Dune](https://hex.pm/packages/dune), a sandbox that runs only an allow-list of modules and functions and limits reductions, heap, time and atom creation.

Why Elixir rather than JavaScript, which is what pi uses and what models write best:

- **Promotion stays in one language** (section 5). A script whose shape is stable becomes a machine: its `Enum.map` over items, its `decide` calls and its error cases become entry functions, typed decisions and transitions almost as written. A promoted script and a hand-written machine look alike, and review reads one language. From JavaScript, every promotion would be a rewrite.
- **One runtime.** No interpreter binary to install, pin and ship in the P8 single binary.
- **Determinism by default** (section 3). The allow-list leaves out the clock, randomness and I/O; the runner supplies `now()` and `random()` and logs them.
- **The glue is small.** Busywork needs `Enum`, pipes, pattern matching on results, and parallelism, which the runner provides as a function (`parallel(items, fun, max: 4)`) rather than letting scripts start processes.

**The sandbox does not run in the daemon's VM.** Dune checks the code against its allow-list and evaluates it in the same VM, so an escape would land in `xeitod`, beside the logs, the key files and the socket. Scripts run instead in a separate, small Erlang VM started through erlexec (`Xeito.Effects.OsCommand`): one warm process per session, so its start-up is paid once. It holds no credentials, is not connected as a distributed Erlang node (a connected node can call anything on the other), and talks to the runner in JSON Lines over its stdin and stdout. It can only ask for the functions of section 1, and the runner performs each one as an effect. A runaway script is killed with its process group, like any command.

**The risk is model fluency.** Small local models write Elixir less reliably than JavaScript. Busywork scripts need little of the language, and a script that does not compile returns the compiler's error to the model like any failed call. The benchmark below measures it: the same busywork set, scripted in Elixir and in JavaScript, on the same local model. If Elixir does clearly worse, the fallback is JavaScript in QuickJS, in an external process in the same way; scripts written for pi would then also run unchanged.

## What Xeito does not try to match

- pi's breadth: fifteen providers, image generation, JavaScript extensions. Xeito's tiers stay few on purpose.
- Scripts that call chat models. pi does not allow it either; a sub-task for a language model is a delegated machine (`Effect.machine`), which is logged and budgeted as a run.
- Long-running scripts as background jobs. A script lives within its turn, like a command.

## How to tell it works

A benchmark (`bench/`) of busywork requests on real repositories, run three ways on the same local model: the chat machine with plain tools, Xeito with scripts, and pi with Codemode on the same Ollama model. Examples: classify every TODO comment by urgency and list the urgent ones; find the tests that failed in the last five CI logs and group them by cause; rate each open issue of a project's tracker export.

Measured: success, model turns, tokens in and out, wall time, and for Xeito the share of calls decided by rules. Xeito's runs are made twice, with scripts in Elixir and in JavaScript (section 7), to settle the language on evidence. The claims to test: scripts cut turns and wall time by an order of magnitude on such requests; Xeito's gates cost little; and a second, similar request after promotion runs without writing a script at all.

## Where it fits

| Step | What | Depends on |
|---|---|---|
| 1 | The `script` effect with read-only tools (`read`, `bash` that Risk rates safe), logged child effects, output shaping, replay; the sandbox VM with Dune | — |
| 2 | Writing tools in scripts, as one undo step; `decide` and `classify`; results as log objects | 1 |
| 3 | MCP client with exposure levels and annotations in Risk (P9's client, brought forward) | 1 |
| 4 | Mining scripts into promotion candidates; the `script` promotion target | P5, P7 |

Steps 1 and 2 could be a phase of their own after P4g, before P5: they are useful without MCP, on files, tests and logs. Step 3 makes P9's MCP client a part of this rather than a bridge.

## Open questions

- How should a script ask for a review in the middle of its run, once that is wanted: pause the whole run, or return what it has and let the model resume?
- Can scripts be written by the small decision tiers for trivial requests, or is it always the `local` model's job?
- Should a promoted script be stored as a skill (a `SKILL.md` with a script file beside it) or as its own kind of artifact?
