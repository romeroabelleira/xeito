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

## Still to check before external publication

- COMPASS: exact title, authors, year.
- TOOLDEC and PMAx: authors.
- Rozinat & van der Aalst (2008), the original token-replay paper: exact citation.
- §7: Jev availability and resale routes (OpenRouter, Vercel, Cloudflare) are disputed in secondary sources. Re-verify all System One numbers before citing them publicly.
