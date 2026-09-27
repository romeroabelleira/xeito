# 11 · Open questions

[← Overview](00-overview.md)

Each question is tagged with the phase of the [implementation plan](../implementation-plan.md) that must answer it.

| # | Question | Options | Decide by |
|---|---|---|---|
| Q1 | Should machines compile into their own `gen_statem` module, or be interpreted by one generic module? | **Decided (P1): interpreted**, through a pure engine shared by the live run and log recovery. | P1 ✅ |
| Q2 | Should machines be written in an Elixir DSL or in a data format (SCXML/YAML)? | **Decided (P1):** a DSL that compiles to validated data. Guards, actions and entry functions are named by atom, and Mermaid/SCXML exports are generated. | P1 ✅ |
| Q3 | Which confidence source is primary for each backend? | **Decided (P2): logprobs everywhere.** One-token scoring on llama-server; logprobs at the value position on Ollama (≥ 0.12). No self-consistency or verbalised confidence needed. | P2 ✅ |
| Q4 | Which small model is the default? | **Decided (P2):** Qwen3.5-2B for the CPU tier. But no small tier passed the zero-shot gate, so every type decides with rules → large ([bench 2](../../bench/2-decisions.md)). | P2 ✅ |
| Q5 | When does a decision type graduate to a classifier? | The thresholds in [03](03-typed-decisions.md) are guesses and need data. | P7 |
| Q6 | What is the right granularity of events for mining (`state_entered` vs effect-level)? | Too coarse hides loops. Too fine produces "spaghetti" models. **Lean:** log everything, filter per analysis. | P5 |
| Q7 | Should mining use the PM4Py sidecar, or a native Elixir implementation? | Sidecar first. Port only DFG and variants. | P5 |
| Q8 | Hologram or LiveView for the inspector? | Decided by the spike ([08](08-tech-stack.md#decision-procedure)). | P6 |
| Q9 | Should Xeito interoperate with pi directly, e.g. pi as the front end over RPC? | Possible if pi's RPC mode is stable ([07](07-harness-frontend.md)). It would avoid building a TUI at all. | P4 |
| Q10 | Should the event log be shared across machines, so that federated mining becomes possible? | Privacy scrubbing ([05](05-event-log-and-process-mining.md#privacy)) is a prerequisite. This would be interesting for research partners. | after v0.1 |
| Q11 | Which license, Apache-2.0 or MPL-2.0? | Apache-2.0 is the Elixir ecosystem norm and fits the grant funders. | P0 |
| Q12 | Should human decisions count toward the determinism budget? | They are explicit but not reproducible. **Lean:** report them separately. | P2 |
| Q16 | Should tier *placement* be dynamic? | **Decided (P3):** yes, as policy. When the large model is not resident, a small-tier answer ≥ `unloaded_accept` is committed instead of swapping ([bench 3](../../bench/3-escalation.md)). Moving the small tier onto an idle GPU stays open. | P3 ✅ |
| Q13 | Is laya-multilingual good enough for low-resource languages and code-switching? | P2: zero-shot Laya scores 0.65–0.76 on intent across en/de/es/gl, and Qwen-2B drops to 0.67 on the low-resource language. Revisit after fine-tuning. | P7 |
| Q14 | Should Xeito ship an adapter so its decision types can call hosted Jev, for benchmarking only? | It is useful as an upper bound on synthetic data. It must be impossible to use on `:local_only` sources. | P3 |
| Q15 | Should Xeito's own decision server also *expose* `/v1/systemone`? | That would let other tools (pi, LiteLLM `/decide`) use Xeito's calibrated cascade as a drop-in Jev replacement. | P3 |
