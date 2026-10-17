# References and prior art

[← Overview](00-overview.md) · Verified 2026-09-27 against primary sources unless marked *(unverified)*.

## How Xeito relates to prior art

- **StateFlow** has already shown the core claim: making the process explicit as a state machine beats free-form ReAct on success rate *and* cost.
- **Anthropic's workflows-vs-agents** distinction and **12-Factor Agents** ("own your control flow") both argue for explicit control over autonomous loops.
- **Stately Agent** is the closest product: machine-defined legal moves, with the LLM choosing among them. It is TypeScript-only and still alpha.
- **Typed decisions** draw on three layers of prior art:
  - decode-time constraints: Outlines, XGrammar, GBNF;
  - parse-and-validate: BAML, Instructor;
  - optimisation: DSPy.
  - DMN adds decision-table semantics.
- **Constrained decoding is automata theory.** A closed-type decision is a token-level FSM nested inside a workflow-level FSM.
- **Self-reported confidence is overconfident.** Escalation must rely on sampling consistency, logprobs or learned scorers instead, as FrugalGPT and RouteLLM do.
- **OCEL 2.0 fits agent runs** better than flat XES. Inductive Miner yields sound models, and alignments give per-step deviations.
- **Process mining of agent traces is emerging but small**: IBM 2025, COMPASS, ProcessTBench, AgentLTL 2026, the 2026 BlueSky agenda. *None closes the full loop of mine → propose → benchmark → release a new machine version.* That loop is Xeito's contribution.
- **OTel GenAI conventions are still in Development.** Xeito emits OTel spans but keeps its own OCEL-mappable schema as the source of truth.
- **System One models** (Jev, Sept 2026, and open clones such as Laya, Kev, SemIf and GLiNER2.5-Decide) turned typed decisions into a product category. Xeito speaks their `/v1/systemone` contract, and it adds the state machine, cascade, log and gate around them ([§7](#7-system-one-decision-models-jev-and-open-clones)).
- **Command effects** are written down per command and per flag (PaSh, CoLiS) or observed by running the command contained (try, hS, Riker). Xeito keeps text rules, requires undo coverage for a safe write, and measures the rules with an asymmetric cost and a run-and-undo oracle ([§8](#8-shell-command-effects-undo-and-agent-safety)).
- **pi** shows that a minimal core is viable: 4 tools, a system prompt under 1k tokens, and extensions for everything else.

## 1. LLMs inside state machines and controlled workflows

| Work | Relevance |
|---|---|
| Wu, Yue, Zhang, Wang, Wu. **StateFlow: Enhancing LLM Task-Solving through State-Driven Workflows.** COLM 2024. [arXiv:2403.11322](https://arxiv.org/abs/2403.11322) · [code](https://github.com/yiranwu0/StateFlow) | Separates "process grounding" (states, transitions) from "sub-task solving" (actions within a state). +13% / +28% success over ReAct on InterCode-SQL / ALFWorld at 5× / 3× lower cost. |
| Crouse, Abdelaziz, Astudillo et al. (IBM). **Formally Specifying the High-Level Behavior of LLM-Based Agents.** 2023. [arXiv:2310.08535](https://arxiv.org/abs/2310.08535) | Declarative behaviour specs are compiled into a decoding monitor that enforces them. |
| **TOOLDEC: Don't Fine-Tune, Decode — Syntax Error-Free Tool Use via Constrained Decoding.** 2023. [arXiv:2310.07075](https://arxiv.org/abs/2310.07075) *(authors unverified)* | FSM-guided decoding for well-formed tool calls. |
| Stately. **Stately Agent** (`@statelyai/agent`). [docs](https://stately.ai/docs/agents) · [GitHub](https://github.com/statelyai/agent) | XState machine = agent. The LLM picks among legal transitions. Alpha. |
| **Apache Burr** (incubating; originally DAGWorks). [burr.apache.org](https://burr.apache.org/) · [GitHub](https://github.com/apache/burr) | Actions + immutable state + transition graph, with its own tracking UI and OTel. |
| LangChain. **LangGraph.** [GitHub](https://github.com/langchain-ai/langgraph) | Graph/state orchestration, checkpointing, human-in-the-loop interrupts. |
| Temporal. **Durable Execution meets AI.** [blog](https://temporal.io/blog/durable-execution-meets-ai-why-temporal-is-the-perfect-foundation-for-ai) | Durable, replayable workflows around LLM activities. Xeito gets durability locally from the event log. |
| Schluntz, Zhang (Anthropic). **Building Effective Agents.** Dec 2024. [anthropic.com](https://www.anthropic.com/engineering/building-effective-agents) | Workflows vs agents; routing, chaining, orchestrator-workers, evaluator-optimizer. "Simple, composable patterns." |
| Horthy / HumanLayer. **12-Factor Agents.** 2025. [GitHub](https://github.com/humanlayer/12-factor-agents) · [Factor 8: Own your control flow](https://github.com/humanlayer/12-factor-agents/blob/main/content/factor-08-own-your-control-flow.md) | Explicit loops, pause/resume between tool selection and execution, the agent as a reducer over state. |

## 2. Typed and structured decisions, routing, calibration

| Work | Relevance |
|---|---|
| OMG. **Decision Model and Notation (DMN) 1.5.** 2023. [omg.org/spec/DMN](https://www.omg.org/spec/DMN) | Decisions as named, typed functions; decision tables and hit policies. The vocabulary for [03](03-typed-decisions.md). |
| BoundaryML. **BAML.** [GitHub](https://github.com/BoundaryML/baml) · [docs](https://docs.boundaryml.com) | LLM calls as typed functions. Schema-aligned parsing. |
| 567 Labs. **Instructor.** [GitHub](https://github.com/567-labs/instructor) | Validated structured outputs with retries. Elixir port: `instructor_ex`. |
| Willard, Louf (.txt). **Efficient Guided Generation for LLMs** (Outlines). 2023. [arXiv:2307.09702](https://arxiv.org/abs/2307.09702) | Generation as FSM transitions. Regex/CFG-constrained decoding. |
| Dong et al. **XGrammar.** 2024. [arXiv:2411.15100](https://arxiv.org/abs/2411.15100) | Near-zero-overhead CFG-constrained decoding. |
| ggml-org. **llama.cpp GBNF grammars / JSON-Schema conversion.** [README](https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md) | The constraint mechanism of the small tier. Supports only a subset of JSON Schema. |
| Khattab et al. **DSPy.** 2023. [arXiv:2310.03714](https://arxiv.org/abs/2310.03714) | Typed signatures + optimisers against a metric. Precedent for improving from data. |
| Pydantic. **Pydantic AI.** [ai.pydantic.dev](https://ai.pydantic.dev) | Typed agent outputs. |
| Chen, Zaharia, Zou. **FrugalGPT.** TMLR 2024. [arXiv:2305.05176](https://arxiv.org/abs/2305.05176) | LLM cascades with a reliability scorer; up to 98% cost reduction. |
| Ong et al. **RouteLLM.** ICLR 2025. [arXiv:2406.18665](https://arxiv.org/abs/2406.18665) | Learned strong/weak routers; >2× cost reduction. |
| Geng et al. **A Survey of Confidence Estimation and Calibration in LLMs.** NAACL 2024. [arXiv:2311.08298](https://arxiv.org/abs/2311.08298) | Background for confidence sources in [03](03-typed-decisions.md#where-confidence-comes-from). |
| Xiong et al. **Can LLMs Express Their Uncertainty?** ICLR 2024. [arXiv:2306.13063](https://arxiv.org/abs/2306.13063) | Verbalised confidence is overconfident; consistency helps. |
| Kadavath et al. (Anthropic). **Language Models (Mostly) Know What They Know.** 2022. [arXiv:2207.05221](https://arxiv.org/abs/2207.05221) | Token-probability calibration on multiple choice supports logprob confidence for closed enums. |

## 3. Process mining

| Work | Relevance |
|---|---|
| van der Aalst. **Process Mining: Data Science in Action**, 2nd ed. Springer 2016. [doi:10.1007/978-3-662-49851-4](https://doi.org/10.1007/978-3-662-49851-4) | Foundations: discovery, conformance, enhancement. |
| Berti, van der Aalst et al. **OCEL 2.0 Specification.** 2023/2024. [arXiv:2403.01975](https://arxiv.org/abs/2403.01975) · [spec PDF](https://www.ocel-standard.org/2.0/ocel20_specification.pdf) | Object-centric events, qualified relations, SQLite/XML/JSON formats. Xeito's log format. |
| IEEE. **1849-2023 XES Standard.** [standards.ieee.org](https://standards.ieee.org/ieee/1849/10907/) · [xes-standard.org](https://www.xes-standard.org/) | Interop baseline for flattened exports. |
| Berti, van Zelst, van der Aalst. **PM4Py.** 2019. [arXiv:1905.06169](https://arxiv.org/abs/1905.06169) · PM4Py.LLM [arXiv:2404.06035](https://arxiv.org/abs/2404.06035) | The mining sidecar. |
| Leemans, Fahland, van der Aalst. **Inductive Miner.** PETRI NETS 2013. [Springer](https://link.springer.com/chapter/10.1007/978-3-642-38697-8_17) · IMf: [Springer](https://link.springer.com/chapter/10.1007/978-3-319-06257-0_6) | Sound, fitting process trees, which can be turned back into statecharts. |
| Carmona, van Dongen, Solti, Weidlich. **Conformance Checking.** Springer 2018. [Springer](https://link.springer.com/book/10.1007/978-3-319-99414-7) | Token replay, alignments. |
| **ICPM, the International Conference on Process Mining.** [icpmconference.org](https://icpmconference.org/) | The venue. The next main conference is Feb 2027 in Rende, Italy. |

**Process mining applied to LLM agents**

| Work | Relevance |
|---|---|
| Fournier, Limonad, David (IBM). **Agentic AI Process Observability: Discovering Behavioral Variability.** 2025. [arXiv:2505.20127](https://arxiv.org/abs/2505.20127) | Discovery + causal analysis over agent traces. The nearest match to [05](05-event-log-and-process-mining.md). |
| **COMPASS: a process-mining-based methodology for prompt analysis.** CEUR-WS Vol-3996. [PDF](https://ceur-ws.org/Vol-3996/paper-5.pdf) *(title/authors unverified)* | Agent logs → event logs → discovery/conformance → prompt feedback. |
| Redis, Fani Sani, Zarrin, Burattin. **ProcessTBench.** 2024. [arXiv:2409.09191](https://arxiv.org/abs/2409.09191) | Conformance of LLM plans against Petri nets. |
| Berti et al. **Re-Thinking Process Mining in the AI-Based Agents Era.** 2024. [arXiv:2408.07720](https://arxiv.org/abs/2408.07720) | The other direction: agents doing process mining. |
| Elkoussy, Perez. **AgentLTL.** Jul 2026. [arXiv:2607.02599](https://arxiv.org/abs/2607.02599) | LTL trace verification for enforcement and as a reward signal. |
| Yang et al. **From Event Logs to Governed Action: A BlueSky Agenda for Agentic Process Mining.** Sep 2026. [arXiv:2609.07984](https://arxiv.org/abs/2609.07984) | Research agenda. Position Xeito relative to it. |
| **PMAx: An Agentic Framework for AI-Driven Process Mining.** 2026. [arXiv:2603.15351](https://arxiv.org/abs/2603.15351) *(authors unverified)* | Agents over OCEL 2.0 logs. |

## 4. Observability

| Work | Relevance |
|---|---|
| **OpenTelemetry GenAI semantic conventions.** [spec](https://opentelemetry.io/docs/specs/semconv/gen-ai/) · [blog 2026](https://opentelemetry.io/blog/2026/genai-observability/) | Status: *Development*, nothing stable. Moved to a separate repository in mid-2026. Use it for export only. |
| **Langfuse.** [langfuse.com](https://langfuse.com) | OSS LLM tracing and evals. Acquired by ClickHouse in Jan 2026. |
| Arize. **Phoenix.** [GitHub](https://github.com/Arize-ai/phoenix) | OTel/OpenInference tracing and evals. |
| **AgentOps.** [GitHub](https://github.com/AgentOps-AI/agentops) | Agent monitoring and cost tracking. |

## 5. Statecharts and runtime

| Work | Relevance |
|---|---|
| Harel. **Statecharts: A Visual Formalism for Complex Systems.** *Sci. Comput. Program.* 8(3), 1987. [doi:10.1016/0167-6423(87)90035-9](https://doi.org/10.1016/0167-6423(87)90035-9) | Hierarchy, concurrency, communication. |
| W3C. **SCXML.** Recommendation, 2015. [w3.org/TR/scxml](https://www.w3.org/TR/scxml/) | Export format for machines. |
| Erlang/OTP. **gen_statem.** [erlang.org](https://www.erlang.org/doc/system/statem.html) | Xeito's runtime: state-enter calls, timeouts, postponed events. |

## 6. The front-end model: pi

| Work | Relevance |
|---|---|
| Zechner. **What I learned building an opinionated and minimal coding agent.** 30 Nov 2025. [mariozechner.at](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/) | The minimalism Xeito's front end copies: 4 tools, a <1k-token prompt, no MCP or sub-agents by default, extensions for the rest. |
| **pi-mono.** [GitHub](https://github.com/badlogic/pi-mono) (now appears under `earendil-works/pi`) · [pi.dev](https://pi.dev) | Four packages: `pi-ai` (providers), `pi-agent-core` (loop), `pi-tui`, `pi-coding-agent`. |
| Earendil. **Pi Durable.** 1 Oct 2026. [earendil.com](https://earendil.com/posts/pi-durable/) · npm `@earendil-works/pi-durable`, `pi-ai`, `chord` (1.3.0, MIT) | A durable harness for many LLM conversations: tasks with phases and checkpoints, tools that declare whether they may run again after a crash, exactly-once submissions, typed documents committed with the transcript; pi-ai's model catalogue and classifiers; chord's versioned JSON protocol with replicated state. Reviewed 2026-10-17: safe replay, error classification, request ids and the client protocol are borrowed ([plan, P4j and P5b](../implementation-plan.md#p4j--robustness)); records overwritten in place and hot reload are not. |
| **Fabric.** Miessler. [GitHub](https://github.com/danielmiessler/fabric) | A library of single-purpose prompts ("patterns") run as Unix filters, with strategies, contexts, a model per pattern and a REST API. The source of [P4g](../implementation-plan.md#p4g--one-shot-mode-and-composable-skills): a one-shot mode, per-skill tier, variables, contexts and a compatible endpoint. Xeito keeps prose as an allowed output and adds typed decisions, machines and the log underneath. |

**Where Xeito deliberately departs from pi:**

- pi rejects sub-agents as black boxes. Xeito has sub-*machines*, which are fully logged and steppable, so they are not black boxes.
- pi calls permission prompts "security theatre". Xeito agrees for yes/no nagging, but replaces it with a typed `Risk` decision, rules first ([10](10-security-and-sandboxing.md)).
- pi puts the loop in the model. Xeito puts it in the machine.

## 7. System One decision models (Jev and open clones)

From the separate "Jev alternatives" research, late Sept 2026. Most accuracy numbers are self-reported or come from week-old community harnesses. Treat them as indicative only.

| Work | Relevance |
|---|---|
| TypeSafe. **Jev** (`jev-1.13.0`), launched 2026-09-15. [docs](https://docs.typesafe.ai/models) · [MarkTechPost](https://www.marktechpost.com/2026/09/19/typesafe-ai-releases-jev/) | A hosted "System One" model with `POST /v1/systemone` and three primitives (Choice ≤ 255 options, Score, Noul), no text output. Leads the independent comparisons. "Cannot hallucinate" means schema-valid, not correct. English-first. Closed and hosted only. |
| Palmer. **Kev** 0.5B / 0.8B / 4B / 9B. [GitHub](https://github.com/jaredpalmer/kev) · [HF 0.5b](https://huggingface.co/jaredpalmer/kev-0.5b) | Qwen + LoRA + pointer head, Jev-compatible API. 0.5B is a superseded prototype (0.561 out-of-domain). 9B reports 0.852 vs Jev 0.857 on shared items. English-trained. |
| **Laya** / laya-multilingual. [GitHub](https://github.com/debjyotikm/laya) · [HF](https://huggingface.co/convaiinnovations/laya) · [issue #54, German routing](https://github.com/NandhaKishorM/laya/issues/54) | A non-autoregressive ModernBERT/mmBERT encoder: one forward pass, CPU-friendly. Zero-shot below the majority-class baseline. Strong only after fine-tuning and calibration. Short German is mis-routed unless `lang` or the model is pinned. |
| **laya-onnx** (navopw). ~~GitHub~~ | A CPU-only ONNX Runtime server with a TypeSafe-compatible API, cited by the research. **The repository returned 404 on 2026-09-27.** The reference deployment uses upstream `laya-serve` instead ([09](09-reference-deployment.md)). |
| **stuntd.** [GitHub](https://github.com/bladedevoff/stuntd) | A proxy that learns an app's typed LLM decisions and answers them with a Laya head. This is the graduation pattern in [03](03-typed-decisions.md). |
| **SemIf-OpenJev.** [GitHub](https://github.com/TheoLeeCJ/SemIf-OpenJev) | "Semantic ifs" over frozen Qwen3.5-4B, including a CPU llama.cpp backend. Auditable. Ranked #2 on JevBench. |
| Fastino. **GLiNER2.5-Decide.** [blog](https://fastino.ai/blog/gliner-2-5-decide-open-weight-decision-model) | DeBERTa-v3 340M, CPU-native, multilingual variant, Apache-2.0. The second `small-s1` candidate. Vendor benchmark only. |
| **DiffusionGemma / djev.** [vLLM PR #57250](https://github.com/vllm-project/vllm/pull/57250) · [GitHub](https://github.com/mmastrac/djev) | Non-autoregressive decisions via diffusion. Datacenter GPU only, not viable on a single workstation. |
| **openJev-verdict-2.0.** [GitHub](https://github.com/Heman10x-NGU/openJev-verdict-2.0) | 150M encoder with claims that are unverified (fine-tuned on its own benchmark). Predecessors did poorly in independent tests. |
| **JevBench.** [GitHub](https://github.com/wayfind/jevbench) | Community benchmark for Jev-class models. Ranks Jev, then SemIf, then djev. Added to the benchmark protocol. |
| LangWatch. **Jev vs tiny open models.** [langwatch.ai](https://langwatch.ai/compare/jev-benchmark) | Safety suites. PII catch rate: Jev 90.8%, Laya 15.8%, Kev-0.8B 22.8%. This is why privacy routing is by source, not by classifier ([04](04-delegation.md#guards-on-escalation)). |

**Takeaway for Xeito.** The typed-decision idea is now a product category, and that validates the thesis. Xeito's contribution is not yet another decision model. It is the machinery *around* decisions:
- state machines that consume them,
- a delegation cascade that prices them,
- an event log that makes them auditable,
- a gate-and-graduate loop that makes local models earn their place.

## 8. Shell command effects, undo and agent safety

Added 2026-10-17 for [command risk](../concepts/command-risk.md); verified that day against primary sources unless marked *(unverified)*.

| Work | Relevance |
|---|---|
| Vasilakis, Kallas, Mamouras, Benetopoulos, Cvetković. **PaSh: Light-touch Data-Parallel Shell Processing.** EuroSys 2021. [doi:10.1145/3447786.3456228](https://doi.org/10.1145/3447786.3456228) · [annotations](https://github.com/binpash/annotations) | Four command classes; per-command JSON records whose cases match on flags and name input and output files. The model for a per-flag command table. |
| Raghavan, Fouladi, Levis, Zaharia. **POSH: A Data-Aware Shell.** USENIX ATC 2020. [usenix.org](https://www.usenix.org/conference/atc20/presentation/raghavan) | An annotation language for the files a command accesses. |
| Kallas, Mustafa, Bielak, Karnikis, Dang, Greenberg, Vasilakis. **Practically Correct, Just-in-Time Shell Script Parallelization.** OSDI 2022. [usenix.org](https://www.usenix.org/conference/osdi22/presentation/kallas) | Decisions at run time, because correctness depends on shell and file-system state. |
| Liargkovas, Kallas, Greenberg, Vasilakis. **Executing Shell Scripts in the Wrong Order, Correctly.** HotOS 2023. [doi:10.1145/3593856.3595891](https://doi.org/10.1145/3593856.3595891) | Trace, contain, then commit or roll back, with read and write sets from system calls in an overlay. |
| Greenberg, Kallas, Vasilakis. **Unix Shell Programming: The Next 50 Years.** HotOS 2021. [doi:10.1145/3458336.3465294](https://doi.org/10.1145/3458336.3465294) | Calls for shared specification libraries of command effects. |
| Lamprou, Jung, Keoliya, Lazarek, Kallas, Greenberg, Vasilakis. **Caruca: Effective and Efficient Specification Mining for Opaque Software Components.** 2025. [arXiv:2510.14279](https://arxiv.org/abs/2510.14279) *(venue unverified)* | Mines file-system pre- and post-conditions of commands with an LLM and system-call interposition. |
| Régis-Gianas, Jeannerod, Treinen. **Morbig: A Static Parser for POSIX Shell.** SLE 2018. [doi:10.1145/3276604.3276615](https://doi.org/10.1145/3276604.3276615) | Static parsing of POSIX shell. |
| Becker, Jeannerod, Marché, Régis-Gianas, Sighireanu, Treinen. **Analysing Installation Scenarios of Debian Packages.** TACAS 2020. [doi:10.1007/978-3-030-45237-7_14](https://doi.org/10.1007/978-3-030-45237-7_14) · utility specs: [HAL](https://hal.inria.fr/hal-02321691) *(content unverified)* | Symbolic execution of maintainer scripts over feature-tree constraints; more than 150 policy violations found. |
| Greenberg, Blatt. **Executable Formal Semantics for the POSIX Shell.** POPL 2020. [doi:10.1145/3371111](https://doi.org/10.1145/3371111) | Smoosh: a POSIX shell semantics with a symbolic stepper. |
| Ridge, Sheets, Tuerk, Giugliano, Madhavapeddy, Sewell. **SibylFS.** SOSP 2015. [doi:10.1145/2815400.2815411](https://doi.org/10.1145/2815400.2815411) | A file-system model used as a test oracle for observed traces. |
| Mazurak, Zdancewic. **ABASH: Finding Bugs in Bash Scripts.** PLAS 2007. [doi:10.1145/1255329.1255347](https://doi.org/10.1145/1255329.1255347) | Abstract interpretation of variable expansion. |
| Moore, Dimoulas, King, Chong. **SHILL: A Secure Shell Scripting Language.** OSDI 2014. [usenix.org](https://www.usenix.org/conference/osdi14/technical-sessions/presentation/moore) | Capabilities and contracts confine what a script may touch. |
| Porter, Hofmann, Rossbach, Benn, Witchel. **Operating System Transactions.** SOSP 2009. [doi:10.1145/1629575.1629591](https://doi.org/10.1145/1629575.1629591) | ACID transactions over system calls: undo at the OS level. |
| binpash. **try.** [GitHub](https://github.com/binpash/try) | Runs a command in an overlay, summarises the changes, then commits or drops them. "A semisolate": the network is not contained. |
| Curtsinger, Barowy. **Riker: Always-Correct and Fast Incremental Builds from Simple Specifications.** USENIX ATC 2022. [usenix.org](https://www.usenix.org/conference/atc22/presentation/curtsinger) | Infers effects by system-call tracing instead of declaring them. |
| Spall, Mitchell, Tobin-Hochstadt. **Build Scripts with Perfect Dependencies.** OOPSLA 2020. [doi:10.1145/3428237](https://doi.org/10.1145/3428237) | Rattle: traced, speculative commands; harmful interleavings named hazards. |
| Weiss, Guha, Brun. **Tortoise: Interactive System Configuration Repair.** ASE 2017. [arXiv:1709.05366](https://arxiv.org/abs/1709.05366) | Records the file-system effects of shell commands with ptrace, in any shell. |
| Hummer, Rosenberg, Oliveira, Eilam. **Testing Idempotence for Infrastructure as Code.** Middleware 2013. [PDF](https://dsg.tuwien.ac.at/team/hummer/docs/2013-middleware-iac.pdf) | Idempotence as the condition for convergence; 92 of about 300 Chef scripts not idempotent. |
| Hanappi, Hummer, Dustdar. **Asserting Reliable Convergence for Configuration Management Scripts.** OOPSLA 2016. [doi:10.1145/2983990.2984000](https://doi.org/10.1145/2983990.2984000) | Convergence under transient faults: the setting of crash recovery. |
| Shambaugh, Weiss, Guha. **Rehearsal: A Configuration Verification Tool for Puppet.** PLDI 2016. [arXiv:1509.05100](https://arxiv.org/abs/1509.05100) | Determinacy and idempotency from a model of file-system effects. |
| Brown, Patterson. **Undo for Operators: Building an Undoable E-mail Store.** USENIX ATC 2003. [usenix.org](https://www.usenix.org/conference/2003-usenix-annual-technical-conference/undo-operators-building-undoable-e-mail-store) | Rewind, repair, replay. Externalized actions are compensated, not undone. |
| GNU. **coreutils `rm` (`--preserve-root`).** [manual](https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html) · ShellCheck **SC2115** [wiki](https://www.shellcheck.net/wiki/SC2115) | Default guard against recursive deletion of `/`; the empty-variable form of the same mistake. |
| IEEE/The Open Group. **POSIX `mkdir`** (1003.1-2024). [pubs.opengroup.org](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mkdir.html) | `-p` is idempotent by specification. |
| Model Context Protocol. **ToolAnnotations** (schema 2025-06-18). [schema.ts](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-06-18/schema.ts) | `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`, kept separate; hints from untrusted servers must not decide. |
| OpenAI. **Codex CLI command safety.** [`is_safe_command.rs` at 3b45c29](https://github.com/openai/codex/blob/3b45c29/codex-rs/shell-command/src/command_safety/is_safe_command.rs) · [removal, 942af84](https://github.com/openai/codex/commit/942af84) | Per-flag exclusions (`rg --pre`, `find -exec`); `git` dropped because repository configuration runs helpers; the list removed on 2026-08-20 for exec-policy rules and sandboxes. |
| Anthropic. **Claude Code permissions and sandboxing.** [permissions](https://code.claude.com/docs/en/permissions) · [sandboxing](https://code.claude.com/docs/en/sandboxing) | A fixed read-only set; rules per subcommand; argument patterns "fragile"; `cd` then `git` prompts because of hooks. |
| OpenHands. **software-agent-sdk security analyzers.** [GitHub](https://github.com/OpenHands/software-agent-sdk) | A model-reported risk level with a pattern analyzer; confirm HIGH and UNKNOWN. |
| Ruan et al. **Identifying the Risks of LM Agents with an LM-Emulated Sandbox** (ToolEmu). ICLR 2024. [arXiv:2309.15817](https://arxiv.org/abs/2309.15817) | 144 cases over 36 emulated toolkits, a terminal among them; severity tied to irreversibility. |
| Yuan et al. **R-Judge: Benchmarking Safety Risk Awareness for LLM Agents.** EMNLP Findings 2024. [arXiv:2401.10019](https://arxiv.org/abs/2401.10019) | 569 recorded interactions judged for risk by models. |
| Guo et al. **RedCode: Risky Code Execution and Generation Benchmark for Code Agents.** NeurIPS 2024 D&B. [arXiv:2411.07781](https://arxiv.org/abs/2411.07781) | 4,050 risky Python and Bash execution cases: a source of review and forbidden examples. |
| Lin, Wang, Zettlemoyer, Ernst. **NL2Bash.** LREC 2018. [arXiv:1802.08979](https://arxiv.org/abs/1802.08979) · [data (MIT)](https://github.com/TellinaTool/nl2bash) | 9,305 English–Bash pairs over 102 utilities: a source of realistic commands to label. |
| Yang, Prabhakar, Narasimhan, Yao. **InterCode.** NeurIPS 2023 D&B. [arXiv:2306.14898](https://arxiv.org/abs/2306.14898) | Bash tasks in Docker, reset by git: a model for the oracle's throwaway workspace. |
| Merrill et al. **Terminal-Bench.** ICLR 2026. [arXiv:2601.11868](https://arxiv.org/abs/2601.11868) | 89 terminal tasks with verification tests; capability, not safety. |
| Liu, Zhang, Yang, Zhang, Feng, Wang, Qiu, Liu, Poczos, Hong. **CARE: Pre-Execution Command Verification for Shell-Executing LLM Agents.** ISSRE 2026. [arXiv:2607.21642](https://arxiv.org/abs/2607.21642) | Shell-command checks with rules first, then an LLM judge; reports F1 and false positives. |
| Tsai, Bagdasarian. **Contextual Agent Security: A Policy for Every Purpose** (Conseca). HotOS 2025. [arXiv:2501.17070](https://arxiv.org/abs/2501.17070) | A bash agent: a static restrictive policy completes 0 of 20 tasks; a contextual one completes 12 and still denies the bad actions. |
| Chennabasappa et al. **LlamaFirewall.** 2025. [arXiv:2505.03574](https://arxiv.org/abs/2505.03574) | Reports attack success and utility together. |
| Bhatt et al. **Ctrl-Z: Controlling AI Agents via Resampling** (BashBench). 2025. [arXiv:2504.10374](https://arxiv.org/abs/2504.10374) | 257 Bash tasks; attack success against usefulness. |
| Kutasov et al. **SHADE-Arena.** 2025. [arXiv:2506.15740](https://arxiv.org/abs/2506.15740) | A monitor's false-positive rate above 20% is "not feasible": review burden has a ceiling. |
| Zhang et al. **Agent-SafetyBench.** 2024. [arXiv:2412.14470](https://arxiv.org/abs/2412.14470) · Kuntz et al. **OS-Harm.** NeurIPS 2025 D&B. [arXiv:2506.14866](https://arxiv.org/abs/2506.14866) | General agent-safety benchmarks; neither is shell-specific *(shell content unverified)*. |

**Takeaway for Xeito.** Research describes command effects per command and per flag (PaSh, CoLiS) or observes them (try, hS, Riker, Rattle); harnesses in daily use have moved to smaller allow-lists with per-flag exclusions (Codex, Claude Code). Xeito keeps rules over the text, but a write is safe only when undo covers it, risk, undoability and repeatability are separate facts, and the rules are measured with an asymmetric cost and an oracle that runs commands and undoes them ([P4k](../implementation-plan.md#p4k--command-effects)).

## Still to check before external publication

- COMPASS: exact title, authors, year.
- TOOLDEC and PMAx: authors.
- Rozinat & van der Aalst (2008), the original token-replay paper: exact citation.
- §7: Jev availability and resale routes (OpenRouter, Vercel, Cloudflare) are disputed in secondary sources. Re-verify all System One numbers before citing them publicly.
- §8: Caruca's venue; the content of the CoLiS utility-specification report (HAL); whether Agent-SafetyBench and OS-Harm contain shell scenarios.
