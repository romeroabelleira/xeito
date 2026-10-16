# Context cost

What typical tasks on this repository cost an agent to read, in tokens (4 characters a token),
measured with `mix xeito.context` over [tasks.exs](tasks.exs). "Prose" is `@moduledoc`/`@doc`
text and comments. A proxy: it counts the files a task needs, not what a given agent actually
opens, so it shows what changes to the code and its documents do, step by step (P4i).

| Date | Commit | Step | Always read | Total, 10 tasks | Prose |
|---|---|---|---|---|---|
| 2026-10-16 | 5a7bf89 | baseline | 845 | 112,151 | 18,857 |
| 2026-10-16 | (P4i 1–5) | glossary, map, contract moduledocs, types | 2,433 | 121,460 | 11,774 |
| 2026-10-17 | (P4i 6) | Session, Tui, chat machine split; tests mirrored | 2,433 | 98,722 | 10,181 |

After steps 1–5 the prose an agent reads per task fell by 38% (18,857 to 11,774 tokens over the
ten tasks), and the code and tests it reads by 6% (103,701 to 97,130). The total rose, by 8%,
because the glossary (about 1,500 tokens) is now read for every task. This proxy cannot count
what the glossary and `mix xeito.map` replace: the searches and document reads an agent makes
to find its way. Splitting the largest modules (step 6) is where the per-task cost falls most:
`session.ex` and `tui.ex` are two thirds of the two dearest tasks.

After step 6 the tasks name the modules they now need (a slash command: `Session.Commands` and
`Session.Info` instead of all of `Session`; the step limit: `Machines.Chat` and `Chat.Limits`).
Against the baseline: 12% fewer tokens per task in total, 46% less prose, and 28% less code and
tests read, the glossary included in every task. The dearest tasks gained most: a slash command
from 20,623 to 11,753 tokens, the chat machine's step limit from 13,447 to 7,600, a TUI key from
25,822 to 18,537.

## Live agents, documents in or out (step 7, 2026-10-17)

Four questions about the code, each asked of a fresh agent (Claude, Claude Code's general-purpose
agent) twice: in this repository (A), and in a copy with `docs/` and `bench/` removed, as if moved
to their own repository (B). Each read `AGENTS.md` first. Tokens are each agent's total.

| Question | A: documents present | B: documents removed |
|---|---|---|
| where the off-box spend limit for remote chat is enforced, its default, how to change it | 57,081 (5 tool calls) | 59,819 (8) |
| what decides whether a bash command runs without asking; approving it for the session | 58,678 (6) | 61,488 (6) |
| how a chat turn ends at its step limit; what happens to edits that fail the checks | 59,873 (7) | 63,990 (7) |
| which tier decides an Intent, in what order tiers would be tried, what keeps off-box tiers out | 65,935 (8) | 64,978 (8) |

All eight answers were right. No agent opened a document: in A they listed `docs/` and grepped
`docs/concepts` beside `lib/` (with `grep -r`, which ignores `.ignore`), but read only code. All
four B agents ran `mix xeito.map`, no A agent did. The difference in tokens (A 60,392 on average,
B 62,569) is within the noise of four runs. Moving the documents out would not save tokens, so
they stay; `AGENTS.md` now asks for `mix xeito.map` before searching, and for `rg` over `grep -r`.

