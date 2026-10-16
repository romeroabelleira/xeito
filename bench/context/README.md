# Context cost

What typical tasks on this repository cost an agent to read, in tokens (4 characters a token),
measured with `mix xeito.context` over [tasks.exs](tasks.exs). "Prose" is `@moduledoc`/`@doc`
text and comments. A proxy: it counts the files a task needs, not what a given agent actually
opens, so it shows what changes to the code and its documents do, step by step (P4i).

| Date | Commit | Step | Always read | Total, 10 tasks | Prose |
|---|---|---|---|---|---|
| 2026-10-16 | 5a7bf89 | baseline | 845 | 112,151 | 18,857 |
| 2026-10-16 | (P4i 1–5) | glossary, map, contract moduledocs, types | 2,433 | 121,460 | 11,774 |

After steps 1–5 the prose an agent reads per task fell by 38% (18,857 to 11,774 tokens over the
ten tasks), and the code and tests it reads by 6% (103,701 to 97,130). The total rose, by 8%,
because the glossary (about 1,500 tokens) is now read for every task. This proxy cannot count
what the glossary and `mix xeito.map` replace: the searches and document reads an agent makes
to find its way. Splitting the largest modules (step 6) is where the per-task cost falls most:
`session.ex` and `tui.ex` are two thirds of the two dearest tasks.
