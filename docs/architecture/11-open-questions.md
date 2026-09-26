# 11 · Open questions

[← Overview](00-overview.md)

Each question is tagged with the phase of the [implementation plan](../implementation-plan.md) that must answer it.

| # | Question | Options | Decide by |
|---|---|---|---|
| Q1 | Should machines compile into their own `gen_statem` module, or be interpreted by one generic module? | Compiled is faster and gives better crash reports. Interpreted allows hot-swapping machine data and is simpler to replay. **Lean: interpreted.** | P1 |
| Q2 | Should machines be written in an Elixir DSL or in a data format (SCXML/YAML)? | A DSL gives compile-time checks. Data makes it easier for mining proposals to edit machines. **Lean:** DSL that compiles to data, with proposals emitted as DSL diffs. | P1 |
| Q3 | Which confidence source is primary for each backend? | logprobs (llama.cpp) · self-consistency · verbalised. It depends on whether Ollama exposes logprobs for the large tier. | P2 |
| Q4 | Which small model is the default? | Decided by the eval results on the reference workstation ([09](09-reference-deployment.md#tier-small-cpu)). | P2 |
| Q5 | When does a decision type graduate to a classifier? | The thresholds in [03](03-typed-decisions.md) are guesses and need data. | P7 |
| Q6 | What is the right granularity of events for mining (`state_entered` vs effect-level)? | Too coarse hides loops. Too fine produces "spaghetti" models. **Lean:** log everything, filter per analysis. | P5 |
| Q7 | Should mining use the PM4Py sidecar, or a native Elixir implementation? | Sidecar first. Port only DFG and variants. | P5 |
| Q8 | Hologram or LiveView for the inspector? | Decided by the spike ([08](08-tech-stack.md#decision-procedure)). | P6 |
| Q9 | Should Xeito interoperate with pi directly, e.g. pi as the front end over RPC? | Possible if pi's RPC mode is stable ([07](07-harness-frontend.md)). It would avoid building a TUI at all. | P4 |
| Q10 | Should the event log be shared across machines, so that federated mining becomes possible? | Privacy scrubbing ([05](05-event-log-and-process-mining.md#privacy)) is a prerequisite. This would be interesting for research partners. | after v0.1 |
| Q11 | Which license, Apache-2.0 or MPL-2.0? | Apache-2.0 is the Elixir ecosystem norm and fits the grant funders. | P0 |
| Q12 | Should human decisions count toward the determinism budget? | They are explicit but not reproducible. **Lean:** report them separately. | P2 |
| Q13 | Is laya-multilingual good enough for low-resource languages and code-switching? | No public evaluation exists. Add them to the eval set. The fallbacks are GLiNER2.5-multi-Decide or the small generative model. | P2 |
| Q14 | Should Xeito ship an adapter so its decision types can call hosted Jev, for benchmarking only? | It is useful as an upper bound on synthetic data. It must be impossible to use on `:local_only` sources. | P3 |
| Q15 | Should Xeito's own decision server also *expose* `/v1/systemone`? | That would let other tools (pi, LiteLLM `/decide`) use Xeito's calibrated cascade as a drop-in Jev replacement. | P3 |
