---
name: xeito-machine
description: Write or change a Xeito machine, the versioned statechart that runs a task on gen_statem (use Xeito.Machine). Use when adding a machine or a state, transition, guard, action, effect, timeout or typed decision to one, when delegating to another machine, when routing requests to a machine, or when deciding whether a change needs a new machine version.
---

# Xeito machines

A machine is the only place control flow lives: models never decide what happens next on their own, they only answer typed decisions that a state asks for. The design is in `docs/architecture/02-state-machine-core.md`; the DSL is documented in `lib/xeito/machine.ex`. Read `lib/xeito/machines/run_tests.ex` (the smallest machine) and `lib/xeito/machines/fix_failing_test.ex` (decisions, nested states, delegation, a human step) before writing one.

## The shape of a machine

```elixir
defmodule Xeito.Machines.Example do
  use Xeito.Machine, version: "0.1.0"

  alias Xeito.Effect

  initial :running

  state :running, entry: :run_check, timeout: 600_000 do
    on :ran, to: :done, guard: :passed?
    on :ran, to: :failed, action: :record_failure
  end

  final :done
  final :failed

  @doc false
  def run_check(ctx), do: [Effect.bash(ctx.cmd, cwd: ctx.cwd)]

  @doc false
  def passed?(_ctx, result), do: result.exit_status == 0

  @doc false
  def record_failure(ctx, result), do: Map.put(ctx, :output, result.output)
end
```

- **Entry functions** return effects (`Xeito.Effect`: `bash`, `read`, `write`, `edit`, `chat`, `machine`, `decide`); they never perform them. The runner executes them, and each result comes back as an event: `:ran` for `bash`, `:child_done` for `machine`, `{:decided, value}` for a decision (the table is in `lib/xeito/effect.ex`). This is what makes runs replayable from the log and sandboxable.
- **Guards** (`fun(ctx, data) :: boolean`) must be pure. The first transition whose event matches and whose guard passes is taken, the innermost state's first, in the order written: put the guarded ones first and an unguarded fallback last.
- **Actions** (`fun(ctx, data) :: ctx`) are pure context updates. Anything with a side effect is an effect of the next state's entry.
- Guards, entries and actions are named public functions, so the definition stays plain data (exportable as Mermaid or SCXML with `mix xeito.export`). Mark them `@doc false`.
- **Nested states:** `state :working, initial: :planning do … end` with child states inside.

## What the compiler enforces (`lib/xeito/machine/validator.ex`)

- Every non-final state has a timeout: `timeout: ms` or `{ms, event}`, else the machine's default (5 minutes). An unhandled timeout ends the run in the mandatory `final :failed`.
- From every state a final state is reachable.
- A state with `decide Type` handles **every** value of the type and `{:decided, :abstain}`. Abstention is a value, not an error: route it somewhere sensible, usually a human.

## Decisions instead of model text

When a step needs judgement (is this test flaky, is this command safe), declare a typed decision in the state rather than parsing model output:

```elixir
state :triage do
  decide(Xeito.Decisions.Triage, input: :triage_input)
  on {:decided, :flaky}, to: :rerun
  on {:decided, :code_bug}, to: :working, action: :record_triage
  on {:decided, :abstain}, to: :ask_human
end
```

A new decision type is a module under `lib/xeito/decisions/` (see `lib/xeito/decision.ex` and `docs/architecture/03-typed-decisions.md`): closed values with descriptions, rules first, labelled examples in `priv/decisions/<type>/examples.jsonl`, evaluated with `mix xeito.eval` before it decides anything.

## Delegation and humans

- Delegate to another machine with `Effect.machine(Module, input, timeout: ms)`. The child runs as its own logged run; the parent gets only its outcome in the `:child_done` event.
- A human step is a state waiting for a human event (`:approved`, `:denied`, `:answered`, or a text answer), with a long timeout: the session relays them (`/approve`, `/deny`, or text).

## Versions

A run pins its machine's version, and recovery refuses to replay a run under a different version. **Bump the version** whenever a run logged with the old code would replay differently: new or renamed states or events, changed transitions or guards, entries that return different effects. A pure refactor that keeps every step the same keeps the version. `mix xeito.log verify` checks that logged runs still replay exactly.

## Registering and routing

A machine that users can start is registered in `lib/xeito/session/router.ex`: the registry (name, module, what it does, how requests reach it), and a routing rule from the Intent value and the message if requests should reach it without `/machine <name>`.

## Testing

Work test-first, at three levels:
1. **Guards and actions** as plain functions on contexts, without a model (as in `test/xeito/chat_machine_test.exs`).
2. **Steps** with `Xeito.Machine.Engine.handle(Xeito.Machine.fetch!(Module), state, ctx, event, data)`, which returns the next state, context and effects without running anything.
3. **Runs** with a scripted runner (`scripted_runner/2` in `test/support/xeito_case.ex`; examples in `test/xeito/run_test.exs`); sessions and routing with the scripted model in `test/xeito/harness_test.exs`.

`test/xeito/architecture_test.exs` fails if a machine, or the engine, calls IO, processes, configuration or the runner side directly: return an effect instead.

A machine whose guards decide something that matters (limits, safety, when to stop) belongs in `test/mutate.exs`, by itself or one `# --- section ---`; see the `xeito-quality-gate` skill.
