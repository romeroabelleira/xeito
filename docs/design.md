# Xeito — Design (one page)

**Status:** draft · 2026-09-27 · Details: [architecture](architecture/00-overview.md) · [plan](implementation-plan.md)

## Problem

Coding agents let a stochastic model run an open loop: decide, act, look, repeat. When they fail, it is hard to say *where*, hard to reproduce, and hard to improve other than by rewriting prompts.
Meanwhile, most of what the model decides is mundane: which tool, is this a flake, is this command safe, are we done. A small local model, or plain code, could make most of those choices.

## Thesis

1. **LLMs behave better in a corset.** When the task is an explicit state machine and the model only picks among the legal transitions, behaviour becomes bounded, comparable and testable. StateFlow (2024) reports higher success at lower cost with exactly this approach, and the Sept 2026 launch of Jev and its open clones shows that typed decisions are now a product category.
2. **Decisions should be typed.** Every branching choice is a closed-type value (enum or tagged union) with confidence and provenance. It is grammar-constrained at decode time, and it can be cached, replayed, evaluated and eventually demoted to a classifier or a rule.
3. **Delegation is a state machine too.** Choosing between rules, a CPU model, a GPU model, an API or a human is a set of guarded transitions with explicit costs, not a hidden retry loop.
4. **Process mining is the meta state machine.** An object-centric event log (OCEL 2.0) of every transition lets us discover what really happens, check conformance with what was intended, find bottlenecks, and feed reviewed changes back into the machines.

## What it is

A pi-style minimalist harness: a terminal, four tools (read, write, edit, bash), a short prompt. Behind it sits an Elixir/OTP daemon where each run is a supervised `gen_statem`.
Runs can be stepped, breakpointed, replayed and benchmarked from the TUI or a local web inspector. A free chat machine keeps unstructured use possible, and mining it shows which machines to write next.

## Reference deployment

It runs on one workstation: a desktop CPU with AVX-512, ≥ 64 GB of RAM and a consumer GPU with ~24 GB of VRAM.

- **small:** a System One decision model (laya-multilingual via upstream `laya-serve`, speaking Jev's `/v1/systemone` contract) and a ~1–2B grammar-constrained model on llama-server, both on the CPU. They graduate by fine-tuning on logged large-model verdicts.
- **large:** `qwen3.6:27b` and `gemma4:31b` through Ollama on the GPU. A model swap is modelled as a costed state.
- **remote:** Claude, gated by policy and budget.

The headline measurement is **accuracy vs Joules per decision** for three setups: large-only, small-only and the cascade.

## Key choices

| Choice | Why |
|---|---|
| **Elixir/OTP** | Processes, supervision, `gen_statem`, telemetry and live introspection *are* the runtime this design needs. Elixir 1.20 adds gradual types. It avoids JS/TS and Rails. |
| **Hologram** for the inspector only | Client-side interactivity written in Elixir. The risks (pre-1.0, bus factor of one) are contained by making the inspector a read model, with Phoenix LiveView as the fallback after a spike. |
| **Out-of-process inference** | llama.cpp and Ollama are faster and safer than NIFs. |
| **OCEL 2.0 in SQLite** | One file per workspace that PM4Py reads directly. It is the single source of truth. |

## Success criteria for v0.1 (~9 months part-time)

- ≥ 60% of decisions taken by rules or the small tier, with no accuracy loss vs large-only.
- Any run can be replayed exactly, and re-decided with a different model.
- A weekly mining report produces machine changes that are accepted and benchmarked.
- The determinism budget of the dogfood machines rises over time.

## Non-goals

A general autonomous agent, hosted SaaS, multi-user operation, or training models from scratch.

## Main risks

The Elixir TUI ecosystem is immature: separate the TUI from the daemon and keep a pi bridge. Small models may be too weak: the cascade covers the gap, and P2 measures it before anything is built on top. Machines may feel rigid: keep the free chat escape hatch.
