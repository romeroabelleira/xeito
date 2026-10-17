# Concept · Command risk: what a command destroys, whether undo takes it back, and whether it may run twice

Status: concept, 2026-10-17, research note. Planned as [P4k](../implementation-plan.md#p4k--command-effects), before P4g continues; the cited works are in [references §8](../architecture/references.md#8-shell-command-effects-undo-and-agent-safety).

## The question

`Xeito.Decisions.Risk` gives one verdict per shell command: `:safe`, `:review` or `:forbidden`. Behind it are three separate questions:

1. **Risk.** Is the command destructive, or does it reach beyond the workspace?
2. **Undoability.** Can `/undo` take its effect back?
3. **Repeatability.** May it run a second time after a crash (`Risk.repeatable?/1`, `Xeito.Effect.replay/1`)?

What does prior work say about deciding these from a command's text? Where does Xeito's answer go wrong today? And how should the answer be measured?

**Short answer.**
- Research tools describe what a command does in **per-command, per-flag specifications**, not hand-written regexes: PaSh, POSH and CoLiS. Where the text cannot settle the question, the stronger tools **trace or contain the command and look at what it actually did**: hS, try, Riker, Rattle and Tortoise.
- Idempotence can be tested: **run twice and compare** (Hummer et al.).
- Undo has a hard boundary. An effect another party has already seen cannot be rewound, only compensated (Brown and Patterson).
- Harnesses in daily use have moved towards smaller allow-lists. Codex removed its list of known-safe commands in August 2026, after first dropping `git` from it.
- Xeito's design is sound, with three problems:
  - Its literal-write rule calls deletions safe that undo cannot restore.
  - Its undo check crashes on paths inside ignored directories.
  - Its allow-list lets through flags that write files or run programs, `git show --output=../x` among them.
- The fix keeps the shape of the design:
  - Every safe write requires `Undo.covers?/3`.
  - Flags go into a table.
  - The three properties become separate, logged facts.
  - Rules are measured with an asymmetric cost and checked against an oracle that runs the commands and undoes them.

## 1. Three properties, not one

| Property | Question | Who answers today | Wrong answer costs |
|---|---|---|---|
| Risk | Does it destroy data, leave the workspace, use the network, run unknown code or touch secrets? | `classify` (regexes, allow-list, literal writes) | data loss or exfiltration |
| Undoability | Would a snapshot hold everything it changes? | `undoable` via `Xeito.Undo.covers?/3`, but only for globs and options | a `:safe` deletion that `/undo` cannot restore |
| Repeatability | Does a second run add nothing to the first? | `Risk.repeatable?/1`: safe by rule and writing nothing | a push or a migration run twice |

These properties are independent:
- `git push` cannot be undone and should not be repeated, yet it may be acceptable after review.
- `rm notes.txt` (tracked) can be undone, but it does not repeat cleanly: the second run fails.
- `mkdir -p out` can be undone, and POSIX makes it idempotent: an existing directory "shall be ignored without error" ([POSIX mkdir](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/mkdir.html)).
- `mix format` writes, but it converges.

The MCP specification keeps the same distinctions as separate hints: `readOnlyHint`, `destructiveHint` ("may perform destructive updates" as opposed to "only additive updates"), `idempotentHint` ("calling the tool repeatedly with the same arguments will have no additional effect") and `openWorldHint`. It also warns that clients "should never make tool use decisions based on ToolAnnotations received from untrusted servers" ([MCP schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-06-18/schema.ts)).

## 2. What prior work says

### 2.1 Effects can be written down per command and per flag

- **PaSh** sorts commands into four classes: stateless, parallelizable pure, non-parallelizable pure and side-effectful. The last one covers "interacting with the filesystem, and accessing the network", and the paper calls it "the largest class". Each command gets "a JSON record" with "a sequence of cases", where each case has a "predicate that matches on the arguments". So a flag can change a command's class and say which arguments are input or output files ([Vasilakis et al., EuroSys 2021](https://doi.org/10.1145/3447786.3456228)). The annotations live in their own repository, one JSON file per command, listing flags and whether an argument is a file ([binpash/annotations](https://github.com/binpash/annotations)).
- **POSH** has "an annotation language that allows POSH to understand which files a command will access" ([Raghavan et al., USENIX ATC 2020](https://www.usenix.org/conference/atc20/presentation/raghavan)).
- **The next 50 years.** Greenberg, Kallas and Vasilakis argue that such specifications "characterize important properties about commands—e.g., their interaction with state", and call for shared specification libraries ([HotOS 2021](https://doi.org/10.1145/3458336.3465294)).
- **Caruca** mines these specifications. An LLM reads the command's documentation, and system-call and file-system interposition checks the result. It mines "filesystem pre- and post-conditions", correct for all but one of 60 commands ([Lamprou et al., arXiv 2025](https://arxiv.org/abs/2510.14279), venue *(unverified)*).
- **CoLiS** parses POSIX shell statically ([Morbig, SLE 2018](https://doi.org/10.1145/3276604.3276615)). It then runs Debian maintainer scripts symbolically over feature-tree constraints, specifying utilities such as `rm`, `mkdir` and `test` by their effect on a file tree. It found more than 150 policy violations ([Becker et al., TACAS 2020](https://doi.org/10.1007/978-3-030-45237-7_14); utility specifications: [HAL report](https://hal.inria.fr/hal-02321691), content *(unverified)*).
- **Semantics** of the shell itself:
  - Smoosh gives POSIX shell an executable semantics with a symbolic stepper ([Greenberg & Blatt, POPL 2020](https://doi.org/10.1145/3371111)).
  - SibylFS gives a file-system model that "can be used as a test oracle to decide whether an observed trace is allowed" ([Ridge et al., SOSP 2015](https://doi.org/10.1145/2815400.2815411)).
  - ABash finds bugs in bash scripts by abstract interpretation of variable expansion ([Mazurak & Zdancewic, PLAS 2007](https://doi.org/10.1145/1255329.1255347)).

**For Xeito.**
- `Risk` keeps four separate pieces of command knowledge: a word list (`@safe_commands`), prefixes (`@safe_prefixes`), substrings to exclude (`@excluded`) and per-command clauses (`read_only?/2`, `command_paths/2`, `sed_options/2`).
- A PaSh-style table gives one record per command: a default class, flag cases that change it, and which arguments it writes. That puts the knowledge in one place. It makes a gap visible as a missing case, not a missing regex, and it is easy to diff and review.
- Xeito needs a different class set from PaSh's. PaSh's classes serve parallelization. Xeito's should serve risk and undo: `read`, `write_args` (writes the files named by its arguments), `write_flag` (writes through an option such as `-o FILE`), `exec` (runs another program), `network` and `unknown`.

### 2.2 Text is not enough: observe what the command did

- **hS** runs shell commands speculatively, out of order. It traces "filesystem-affecting system calls" into read and write sets in namespaces with OverlayFS, and commits a command only when its reads do not conflict with earlier uncommitted writes. The scheduler "must be able to trace, contain, and merge (or rollback)" ([Liargkovas et al., HotOS 2023](https://doi.org/10.1145/3593856.3595891)).
- **try** runs a command in namespaces over overlayfs, shows a summary of the changes and asks "Commit these changes? [y/N]". It calls itself "a semisolate (as opposed to a fully isolated sandbox)": the network is not contained ([binpash/try](https://github.com/binpash/try)).
- **Build systems that trace.**
  - Riker "executes commands under system call tracing" so that "every dependency is checked on every build" ([Curtsinger & Barowy, USENIX ATC 2022](https://www.usenix.org/conference/atc22/presentation/curtsinger)).
  - Rattle traces the commands of a build script and runs them speculatively. It names a harmful interleaving (for example "read then write") a *hazard* ([Spall, Mitchell & Tobin-Hochstadt, OOPSLA 2020](https://doi.org/10.1145/3428237)).
  - Tortoise uses ptrace to "record all system calls and file system changes made from the shell", in "all existing shells" ([Weiss, Guha & Brun, ASE 2017](https://arxiv.org/abs/1709.05366)).
- **Containment by construction.**
  - Shill confines scripts with "language-level capabilities and contracts" ([Moore et al., OSDI 2014](https://www.usenix.org/conference/osdi14/technical-sessions/presentation/moore)).
  - TxOS gives system calls ACID transactions ([Porter et al., SOSP 2009](https://doi.org/10.1145/1629575.1629591)).

**For Xeito.**
- `Undo.step/5` already observes effects: it compares snapshots before and after. What it lacks is *preview*.
- A command that rules send to review could run first in an overlay, as `try` does. The human would then review a list of changes ("deletes 312 files under `priv/`"), not a string.
- That belongs in the `contained` policy level ([10](../architecture/10-security-and-sandboxing.md#effect-policy-levels)). It needs Linux user namespaces, and it does nothing about the network.
- It is the only way to decide on `make`, scripts and `npm install`, whose writes the text never shows. Leave it for later (section 7, step 7).

### 2.3 Idempotence and convergence can be tested

- **Hummer et al.** state that steps "should be idempotent to guarantee repeatability and convergence", and that "idempotence is a requirement for convergence". They test Chef scripts by running them from generated start states. Of "roughly 300" real scripts, "3671 test cases" found "92 of those scripts as non-idempotent" ([Hummer, Rosenberg, Oliveira & Eilam, Middleware 2013](https://dsg.tuwien.ac.at/team/hummer/docs/2013-middleware-iac.pdf)).
- **Hanappi et al.** check convergence under transient faults: "It is crucial for convergent configurations to be able to gracefully handle transient faults" ([Hanappi, Hummer & Dustdar, OOPSLA 2016](https://doi.org/10.1145/2983990.2984000)).
- **Rehearsal** builds a "sound, complete, and scalable determinacy analysis for Puppet" on a model of file-system effects, and uses it to check idempotency ([Shambaugh, Weiss & Guha, PLDI 2016](https://arxiv.org/abs/1509.05100)).

**For Xeito.**
- Crash recovery re-dispatches a pending effect ([P4j step 1](../implementation-plan.md#p4j--robustness)). That is exactly the "transient fault" setting.
- The test is cheap and needs no theory. Run the command twice from the same start state and compare the state after one run with the state after two (section 6.3).
- `repeatable?/1` today means "safe by rule and writes nothing". That is conservative but too blunt. It refuses `mkdir -p` and `touch`, which are idempotent, and accepts allow-listed commands that write through flags (gap G3).

### 2.4 Undo has a boundary

- **Brown and Patterson** define operator undo as the "Three R's: Rewind, Repair, and Replay". They record each action whose effect is "changed or externalized (exposed to an external observer)". An externalized effect that replay would change is a paradox, in their words like "time travel paradoxes", handled by a "compensation procedure" ([USENIX ATC 2003](https://www.usenix.org/conference/2003-usenix-annual-technical-conference/undo-operators-building-undoable-e-mail-store)).
- **Guards against the classic deletion.**
  - GNU `rm` refuses to remove `/` recursively by default (`--preserve-root`, [coreutils manual](https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html)).
  - ShellCheck SC2115 warns that an empty variable makes `rm -rf "$VAR/"*` delete from the root ([SC2115](https://www.shellcheck.net/wiki/SC2115)). Xeito's tokenizer refuses `$` in paths, so that case goes to review.

**For Xeito.** The boundary of `/undo` is the snapshot. Inside it: tracked files, untracked files that are not ignored, small ignored files (`lib/xeito/undo.ex:11-13`). Outside it:
- **Inside the workspace but not captured:** ignored directories, files over 5 MB, workspaces over 20,000 files, and the protected directories.
- **Outside the workspace:** paths not named literally (`Xeito.Undo.Outside`).
- **Externalized effects:** network, `git push`, package installs into global locations, processes started, messages sent. These are Brown and Patterson's externalized actions. `Undo.Branch` already treats a pushed commit this way: it offers a `git revert`, which is a compensation, not an undo.

A verdict of `:safe` because of undo is only sound inside that boundary.

### 2.5 What other harnesses do

All code below was read at the repositories' heads on 2026-10-17.

- **Codex CLI.**
  - It removed its list of known-safe commands on 2026-08-20: "Projects marked untrusted now request approval for every command unless an explicit exec policy rule allows it" ([commit 942af84](https://github.com/openai/codex/commit/942af84)).
  - The day before, it took `git` off the list, because "Repository configuration can cause even read-only Git commands to execute helpers" ([3b45c29](https://github.com/openai/codex/commit/3b45c29)).
  - The last version of the list ([`is_safe_command.rs` at 3b45c29](https://github.com/openai/codex/blob/3b45c29/codex-rs/shell-command/src/command_safety/is_safe_command.rs)) excluded:
    - `find` with `-exec`, `-execdir`, `-ok`, `-okdir`, `-delete`, `-fls` and the `-fprint` family;
    - `rg` with `--pre`, `--hostname-bin`, `--search-zip` and `-z`;
    - `base64 -o`;
    - every `sed` except `sed -n Np`.
  - Scripts are parsed with tree-sitter-bash. Only plain words joined by `&&`, `||`, `;` and `|` count as provable.
  - What stays is a Starlark `prefix_rule` policy, plus the sandbox modes: read-only, workspace-write and full access ([execpolicy README](https://github.com/openai/codex/blob/main/codex-rs/execpolicy/README.md)).
- **Claude Code.**
  - Its read-only set is fixed: "ls, cat, echo, pwd, head, tail, grep, find, wc, which, diff, stat, du, cd, and read-only forms of git".
  - Rules must "match each subcommand independently", and it warns that "Bash permission patterns that try to constrain command arguments are fragile".
  - `cd` followed by `git` prompts, because git "can execute that directory's hooks" ([permissions](https://code.claude.com/docs/en/permissions)).
  - The sandbox, bubblewrap on Linux, is off by default ([sandboxing](https://code.claude.com/docs/en/sandboxing)).
- **Gemini CLI** asks about every shell command by default, except an approved list in sandbox mode: `cat`, `ls`, `grep`, `head`, `tail`, `less`, `echo` ([policies](https://github.com/google-gemini/gemini-cli/tree/main/packages/core/src/policy/policies)).
- **OpenHands** has the model fill in a `security_risk` field (LOW/MEDIUM/HIGH), adds a deterministic pattern analyzer, and asks to confirm HIGH and UNKNOWN by default ([software-agent-sdk, `security/`](https://github.com/OpenHands/software-agent-sdk)).
- **Aider** asks about every suggested command, even with `--yes-always` ([`aider/io.py`](https://github.com/Aider-AI/aider/blob/main/aider/io.py)).

**For Xeito.**
- Xeito's list is longer than any of these. It has `git` prefixes, build and test commands, `sort`, `tree` and `rg` with no flag checks.
- The lesson from Codex and Claude Code is not "no allow-list". It is two things: allow-lists need per-flag exclusions, and `git` and build tools run code the repository supplies.
- Xeito's answer to that second point is a stated trust assumption (section 7a), not silence.

### 2.6 How agent safety is measured

- **ToolEmu** emulates 36 toolkits, a `Terminal` among them, on 144 cases. It scores safety 0–3, where "severe" means "significant and often irreversible". Its `rm -rf /*` case, rebuilt in a real sandbox, crashed the VM ([Ruan et al., ICLR 2024](https://arxiv.org/abs/2309.15817)).
- **R-Judge** asks models to judge 569 recorded agent interactions for risk ([Yuan et al., EMNLP Findings 2024](https://arxiv.org/abs/2401.10019)).
- **RedCode-Exec** has 4,050 risky Python and Bash cases, file systems among its domains ([Guo et al., NeurIPS 2024 D&B](https://arxiv.org/abs/2411.07781)).
- **Corpora without safety labels:**
  - NL2Bash: 9,305 English–Bash pairs over 102 utilities; the data is MIT-licensed ([Lin et al., LREC 2018](https://arxiv.org/abs/1802.08979); [repo](https://github.com/TellinaTool/nl2bash)).
  - InterCode Bash: 200 NL2Bash tasks in Docker, reset by git between episodes ([Yang et al., NeurIPS 2023 D&B](https://arxiv.org/abs/2306.14898)).
  - Terminal-Bench 2.0: 89 tasks, with verification tests ([Merrill et al., ICLR 2026](https://arxiv.org/abs/2601.11868)).
- **Guards that report both kinds of error:**
  - CARE checks shell commands with static rules first, then an LLM judge for ambiguous cases: 85.64% F1 at 0.91% false positives ([Liu et al., "CARE: Pre-Execution Command Verification for Shell-Executing LLM Agents", ISSRE 2026](https://arxiv.org/abs/2607.21642)).
  - Conseca's prototype is a Linux agent whose tool APIs "are bash commands". A static restrictive policy completed 0 of 20 tasks; the contextual policy completed 12 and still denied the inappropriate actions ([Tsai & Bagdasarian, HotOS 2025](https://arxiv.org/abs/2501.17070)).
  - LlamaFirewall's AlignmentCheck reaches over 80% recall under 4% false positives ([Chennabasappa et al., 2025](https://arxiv.org/abs/2505.03574)).
  - Ctrl-Z (BashBench, 257 tasks) cuts attack success from 58% to 7% at about 5% lost usefulness ([Bhatt et al., 2025](https://arxiv.org/abs/2504.10374)).
  - SHADE-Arena reports the other side: at 80% detection a monitor's false-positive rate above 20% is "not feasible" for deployment ([Kutasov et al., 2025](https://arxiv.org/abs/2506.15740)).

**For Xeito.**
- No paper weights the two errors formally. All of the practical ones report them as a pair: harm let through against work blocked.
- Xeito's gate (`Xeito.Decision.Eval.gate/2`) compares accuracy only. Accuracy treats a forbidden command called safe the same as a safe command sent to review.
- CARE has Xeito's own shape: rules first, then a model for ambiguous cases.

## 3. Gaps in Xeito's code

Reproduced on 2026-10-17 in a temporary git workspace containing `.gitignore` with `build/`, `build/cache/x`, `build/out.bin`, a tracked-size `notes.txt` and a 6 MB `big.bin`.

**G1. Literal writes are safe without undo coverage.**
- `classify` (`lib/xeito/decisions/risk.ex:103-110`) returns `:safe` from `writes_inside?/2` (`:160-168`), which checks only that each path is inside the workspace (`inside?/2`, `:344-350`).
- `undoable` (`:243-251`) also asks `Xeito.Undo.covers?/3` (`:258-263`).
- Rules apply first-match (`Xeito.Decider.apply_rules/2`, `lib/xeito/decider.ex:57-70`), so `classify` wins.

Observed:

| Command | Verdict | Restorable by `/undo`? |
|---|---|---|
| `rm -rf build` | `:safe` | no: `build/` is ignored |
| `rm big.bin` | `:safe` | no: over 5 MB |
| `rm -f big.*` | `nil`, so review | (same file) |
| `rm build/cache/x` | `:safe` | no |

The same deletion gets a different verdict depending on how it is spelled. [10](../architecture/10-security-and-sandboxing.md) says "the premise is that the workspace is under version control, so such a write can be undone". Since stage 3 of undo, Xeito can check that premise instead of assuming it.

**G2. `Undo.covers?/3` crashes on a path inside an ignored directory.**
- `uncaptured/3` (`lib/xeito/undo.ex:86-107`) matches `{ignored, 0}` on `git ls-files --others --ignored --exclude-standard --directory -- build/cache/x`.
- Git (2.43) exits 128: "internal error - directory entry not superset of prefix". `{"", 128}` does not match `{ignored, 0}`, so `covers?/3` raises a MatchError.
- `covers?(ws, ["build/out.bin"])` (one level deep) returns `false`, as `test/xeito/undo_test.exs:227` expects. `["build/cache/x"]` raises.
- So `rm -f build/cache/*` raises inside the rules tier. In a run, `Xeito.Effects.safe_run/3` (`lib/xeito/effects.ex:39-43`) turns the raise into `:abstain`, and the chat machine sends `:abstain` to review (`lib/xeito/machines/chat.ex:108-115`). The outcome is safe by accident:
  - the decision logs an error, not a rule;
  - the model tier never runs;
  - `mix xeito.eval` calls `Decider.apply_rules/2` directly (`lib/xeito/decision/eval.ex:74-79`), so one such example would abort the whole evaluation.

**G3. Allow-listed commands write or execute through flags, and count as repeatable.** Fixed in P4k step 3, with more such flags than listed here (`sort --compress-program`, `tree -R`, `less -o`, `file -C`, `uniq IN OUT`).

`@safe_commands` and `@safe_prefixes` (`lib/xeito/decisions/risk.ex:71-97`) match the first word or a prefix. `@excluded` (`:100`) knows only `-delete`, `-exec`, `--force` and secret names. Observed `:safe` and `repeatable?: true`:

| Command | Real effect |
|---|---|
| `rg --pre sh x` | runs `sh` on each file (Codex excluded `--pre`) |
| `rg -z x` | runs decompressors |
| `sort -o out.txt in.txt` | writes a file |
| `tree -o out.txt` | writes a file |
| `git diff --output=x.txt` | writes a file |
| `git log --output=x.txt` | writes a file |
| `git show --output=../x` | writes **outside the workspace** |
| `git branch -D main` | deletes a branch |
| `git branch -m main old` | renames a branch |

`find` is handled correctly: `-execdir` and `-fprintf` go to review, because `-exec` and `-fprint` match them as substrings.

**G4. The trust assumption is unstated.**
- `git status|diff|log|show`, `mix test`, `cargo build`, `npm test`, `make test` and `pytest` run code or helpers that the repository supplies: build scripts, test code, git's configured helpers. Codex dropped `git` from its list for this reason, and Claude Code prompts on `cd` followed by `git` for the hooks.
- For Xeito's case, a workspace the user develops in, this is acceptable. But it is a premise, and [10](../architecture/10-security-and-sandboxing.md) should say so.

**G5. `repeatable?/1` is derived from risk, not from effects** (`lib/xeito/decisions/risk.ex:117-119`).
- It refuses idempotent writes (`mkdir -p a`, `touch a`). That is conservative and acceptable.
- It accepts the G3 writers and `mix deps.get` (network). The network part is benign, since a repeated fetch converges, but by luck, not by design.

**G6. The evaluation set does not exercise the write rules.**
- None of the 159 examples in `priv/decisions/risk/examples.jsonl` has a `cwd`. So `writes_inside?/2` and `undoable` are never evaluated there: they are tested only in `test/xeito/decision_test.exs:304-503`.
- The gate is symmetric accuracy (`lib/xeito/decision/eval.ex:221-241`).
- `dangerous_missed` (`lib/mix/tasks/xeito.eval.ex:88-97`) counts only the rules tier's misses of `:forbidden`. Nothing counts a review command called safe, except one test (`test/xeito/decision_test.exs:166`).

**G8. A new file over the snapshot limit** (found by the oracle, P4k step 6). `cat big.bin > copy.bin` is safe by rule: its one written path does not exist yet, so `covers?/3` holds. Undo then leaves the 5 MB copy behind, since a step records oversized files only as skipped. Undo should remove a file the step created and could not capture.

**G9. A forbidden command followed by another was only reviewed** (found by the property tests, fixed in P4k step 6). Patterns anchored at the end of the line (`rm -rf ~/`, `rm /`) no longer matched once a command followed: `rm -rf ~/ ; ls` went to review. Each pattern now also runs on each part of the command.

**G7. `ls -la notes.txt; rm -v notes.txt` is safe by rule.** By design: a literal deletion inside the workspace. After the fix for G1 it stays safe only when the file is captured.

## 4. Text rules versus observed effects

| Approach | Decides | Costs | Where in Xeito |
|---|---|---|---|
| Regexes and allow-list | obvious cases, fast | misses flags (G3); grows by accretion | `classify` today |
| Per-command, per-flag table (PaSh style) | which arguments are written, which flags change the class | one record per command; unknown commands stay unknown | proposed (step 4) |
| Undo coverage check | whether a known write is restorable | one `git ls-files` per decision | `undoable`; proposed for all writes (step 2) |
| Trace or overlay, then commit (hS, try, Rattle) | anything, including `make` and scripts | Linux namespaces; the network is not contained; latency | `contained` level, later (step 7) |
| Model fallback | review against forbidden only | latency; can only raise | `:local` tier today |

The rules can only ever answer from the text. The table makes them honest about which flags they know. The undo check makes "safe" mean "restorable". The overlay is the step that turns review of a string into review of an effect.

## 5. The model fallback, precisely

The floor is `:review`, and a model can only raise a verdict to `:forbidden` (`severity … floor: :review`, `lib/xeito/decisions/risk.ex:33`). So **a model never makes anything safe**. Its whole job is a binary choice: block, or let a human decide. Evaluate it as that:
- **forbidden recall** on commands labelled forbidden that the rules do not catch;
- **false-forbidden rate** on commands labelled review: a wrong block costs the user a rephrase, and the model a turn.

Its effect on the false-safe rate is zero by construction. A test should pin that down: the pipeline's safe set equals the rules' safe set.

## 6. Evaluation method

Everything here uses machinery that already exists: `priv/decisions/risk/examples.jsonl`, `Xeito.Decision.Eval`, `mix xeito.eval`, the gate, StreamData (already a test dependency, used in `test/xeito/run_property_test.exs`), and mutation testing (`risk.ex` and `undo.ex` are both in `test/mutate.exs`).

### 6.1 A labelled corpus with workspaces

Each example gets an optional `fixture`: the name of a workspace built by a test helper (`test/support/xeito/risk_fixtures.ex`). The fixtures:
- `tracked`: a git repository with tracked files;
- `untracked`: as `tracked`, plus untracked files;
- `ignored_dir`: `build/` ignored, with nested files;
- `big_file`: a file over `:max_file_bytes`;
- `outside_link`: a symlink to a directory outside;
- `secrets`: `.env` and a fake key;
- `no_git`: not a repository.

The example's `cwd` is the built fixture. Labels per property:

| Field | Values | Meaning |
|---|---|---|
| `label` | `safe` / `review` / `forbidden` | as today |
| `undoable` | `true` / `false` / `null` | `/undo` restores the fixture exactly (`null`: changes nothing) |
| `repeatable` | `true` / `false` | a second run from the post-state leaves it unchanged |
| `effects` | subset of `read`, `write`, `delete`, `outside`, `network`, `exec`, `secret` | for the table and for analysis |
| `dangerous` | boolean | as today: must be blocked by rules |

Sources, each tagged in `source`:
1. **The existing tests.** Every command in the Risk and `covers?` tests, with its fixture. These are the regression core.
2. **NL2Bash** (MIT data). Commands sampled per utility and relabelled for the fixtures: about 300, stratified so every utility on Xeito's lists, and every writer, appears with its common flags.
3. **Benchmark tasks.** Commands from InterCode Bash and Terminal-Bench solutions (licenses to check before vendoring), and RedCode-Exec's Bash cases for the forbidden and review side.
4. **Xeito's own log.** Every `bash` effect with its Risk verdict, the human's answer to a review (approve or deny), and `step_undone` events. These are real labels: an approved review is evidence of "acceptable"; an undone step is evidence that undo was needed and worked. The public repository is the hard rule here: mined commands go to the private companion repository. Only synthetic or scrubbed commands are committed.
5. **Mutations of safe commands.** For each safe example, add one dangerous flag from the table (`-o FILE`, `--pre CMD`, `--output=../x`, `-D`). This is how G3 would have been found.

Target: 600–800 examples, at least a third with a fixture, every gap in section 3 represented.

### 6.2 Metrics that weigh errors asymmetrically

Add these to `Eval.metrics/2` for types that declare a severity order (Risk does):
- **False-safe rate**: labelled `review` or `forbidden`, predicted `safe`. The gate requires **zero** for the rules tier and the pipeline, on the whole set and not only on `dangerous`.
- **False-safe on undo**: predicted `safe` with `undoable: false` and a label that is not `safe`. This is G1's metric.
- **Review burden**: labelled `safe`, predicted `review`, as a share of all `safe`. This is what the rules try to cut, and the only number a rule change may trade against.
- **Forbidden recall** and **false-forbidden rate** (section 5).
- **Expected cost** over a fixed matrix:

  | predicted \ actual | safe | review | forbidden |
  |---|---|---|---|
  | **safe** | 0 | 20 | 100 |
  | **review** | 1 | 0 | 5 |
  | **forbidden** | 3 | 2 | 0 |

  The numbers are a starting point to argue about. The ordering is not: calling a dangerous command safe must dominate.
- **The gate for Risk.** A change to the rules or a candidate tier passes when its false-safe rate stays at zero and its expected cost does not rise. Report review burden beside it. Accuracy stays in the report as context.

### 6.3 A differential oracle: run, undo, compare; run twice, compare

A test helper, `Xeito.Test.RiskOracle`, runs each corpus command that has a fixture and a label other than `forbidden`:
1. Build the fixture in a fresh temporary directory, plus a sibling `outside/` directory and a temporary `HOME`. Record a full digest: every file, ignored and oversized ones included, with mode and symlink target, for the workspace, `outside/` and `HOME`.
2. Run the command with `sh -c` inside `Xeito.Undo.step/5`, with the network cut where the platform allows (`unshare -n` when available; otherwise network-labelled commands are skipped) and a short timeout.
3. **Undoability.** Call `Xeito.Undo.undo/3`, then digest again. Observed undoable means the digests match.
4. **Repeatability.** Rebuild the fixture and run the command twice. Observed repeatable means the digest after one run equals the digest after two, and the second exit status means the same thing as the first.
5. **Outside writes.** Any change to `outside/` or `HOME` is recorded as an outside effect.

The checks, as test assertions:
- Rules say `:safe` with any write ⇒ observed undoable. This catches G1.
- `repeatable?/1` ⇒ observed repeatable, and no outside effect. This catches G3.
- `written_paths/1` ⇒ a superset of the paths the digest shows changed. This catches flag writes.
- The labels in the corpus agree with what is observed. A disagreement is a labelling error or a finding, and either is worth seeing.

The oracle runs real commands, so it is tagged `:oracle` and excluded from `mix test`. It runs in `mix ci` inside the existing container, or by hand through `scripts/try-local.sh`. Forbidden examples are never run.

### 6.4 Property-based tests

With StreamData, generate commands from a small grammar: a command from the lists and the table, flags (including the dangerous ones), path kinds (tracked, untracked, ignored, big, outside, through a symlink, a glob, quoted), and separators. Properties:
1. **Total.** `classify/1`, `undoable/1`, `repeatable?/1` and `Undo.covers?/3` return a value for every generated input, and never raise. This catches G2.
2. **Monotone in segments.** The verdict of `a; b` is at least the verdict of each of `a` and `b`, in severity order.
3. **Safe writes are covered.** `classify` is `:safe` with written paths ⇒ `Undo.covers?(cwd, paths)`.
4. **Repeatable implies safe**, and implies no written paths.
5. **Quoting invariance.** `x` and `'x'` give the same verdict for plain words.

### 6.5 Mutation testing

`risk.ex` and `undo.ex` are already held to zero surviving mutants. The new table (step 4) and the oracle-backed checks join that list. A surviving mutant in a flag case means no example exercises that flag: add the example.

## 7. Recommendations

### (a) Concept and architecture documents

Applied with this note, on 2026-10-17. P4k steps 1 and 2 brought the code in line the same day: G1 and G2 are fixed.

- **[10 · Security](../architecture/10-security-and-sandboxing.md), the paragraph on writes inside the workspace.** Replace "the premise is that the workspace is under version control, so such a write can be undone" with: a write is safe by rule only when its paths are literal, inside the workspace, and covered by an undo snapshot (`Xeito.Undo.covers?/3`). Then list what is not covered: ignored directories, files over the size limit, large workspaces, protected directories, paths outside, and externalized effects (network, pushes, installs). Add one sentence on trust: build, test and `git` commands run code the repository supplies, so they are safe by rule only in a workspace the user already trusts; a workspace from elsewhere starts in review for them.
- **[10 · Security](../architecture/10-security-and-sandboxing.md), the threat model.** Add a row: *"A flag that writes or runs: `sort -o`, `rg --pre`, `git … --output`. Mitigation: per-flag cases in the command table."*
- **[03 · Typed decisions](../architecture/03-typed-decisions.md), the `Risk` row.** State the three properties. The verdict is `:safe | :review | :forbidden`; undoability and repeatability are facts the rules compute and log with it, not values of the type.
- **[11 · Open questions](../architecture/11-open-questions.md).** Add:
  - *Q17: Should review show observed effects (an overlay run, as in `try`) instead of the command text?* Lean: yes, at the `contained` level, Linux first. Decide by P8.
  - *Q18: Should the command table be shared with PaSh's annotation format, or stay Xeito's own?* Lean: Xeito's own classes, PaSh's case-and-predicate shape.
- **[references](../architecture/references.md).** A new section, [8. Shell command effects, undo and agent safety](../architecture/references.md#8-shell-command-effects-undo-and-agent-safety), with every work cited here. Done with this note.

### (b) Implementation-plan additions (P4k · Command effects)

Each step is test-first: the failing test named in the step comes before the code.

1. **`covers?/3` is total.**
   - Test: in `test/xeito/undo_test.exs`, `covers?(ws, ["build/cache/x"])` and `covers?(ws, ["build/cache"])` are `false` (they raise today).
   - Code: any nonzero exit from either `ls-files` means not covered. A path under an ignored directory is uncovered by definition, so test for it with `git check-ignore -q --no-index` on each path, or its nearest existing parent, before listing.
   - Exit: `rm -f build/cache/*` is `nil` from the rules (review), with no raise; a property test (6.4, property 1) holds over generated paths.
2. **Literal writes need coverage.**
   - Test: on the `ignored_dir` and `big_file` fixtures, `rm -rf build`, `rm build/cache/x` and `rm big.bin` are not `:safe`; `rm notes.txt` (tracked) and `echo x > new.txt` stay `:safe`.
   - Code: `writes_inside?/2` also calls `Xeito.Undo.covers?(cwd, paths)`.
   - Exit: the same deletion gets the same verdict however it is spelled, and [10](../architecture/10-security-and-sandboxing.md) is updated.
3. **Close the flag holes.**
   - Test: a table test with every command in G3, each expected `nil`, and each also not `repeatable?`.
   - Code: per-command flag exclusions: `rg` (`--pre`, `--pre-glob`, `-z`, `--search-zip`, `--hostname-bin`), `sort` (`-o`, `--output`), `tree` (`-o`), `git diff|log|show` (`--output`, `--ext-diff`, `--textconv`), and `git branch` (list forms only: no `-d`, `-D`, `-m`, `-M`, `-c`, `-C`, `--set-upstream-to`, `-u`, `--edit-description`, nor a bare new branch name).
   - Exit: no command in the corpus writes a path outside `written_paths/1` (checked by the oracle in step 5).
4. **A command table.**
   - Test: a test that every command named in `Risk` has exactly one record, and that each record's cases are pinned by examples (mutation testing).
   - Code: one module, `Xeito.Decisions.Risk.Commands`, as data, one record per command: a default class (`read`, `write_args`, `write_flag`, `exec`, `network`, `unknown`), flag cases with a predicate and the class they give, and which arguments are written. `@safe_commands`, `@safe_prefixes`, `@excluded`, `read_only?/2` and `command_paths/2` become lookups in it.
   - Exit: `risk.ex` and the table pass the mutation gate; existing tests unchanged.
5. **Three properties, logged.**
   - Test: for a set of commands, `Risk.assess/2` returns the expected `%{effects, written, outside, undoable, repeatable}`.
   - Code: `classify`, `undoable` and `repeatable?/1` are derived from `assess/2`. `repeatable` is true for reads and for writes the table marks idempotent (`mkdir -p`, `touch`). `Effect.replay/1` uses it. The decision logs `undoable` and `repeatable` as inputs, as stage 3 of undo already planned for `undoable`.
   - Exit: a run killed during `mkdir -p out && touch out/x` replays it; one killed during `git branch -D x` does not.
6. **The corpus, the metrics and the oracle** (section 6).
   - Test: `Eval.metrics/2` reports false-safe rate, review burden and expected cost on a fixed toy set.
   - Code: fixtures, the new fields in `examples.jsonl`, the cost matrix, the Risk gate, and `Xeito.Test.RiskOracle` tagged `:oracle`.
   - Exit: `mix xeito.eval risk` reports the new metrics with a false-safe rate of zero for rules and pipeline; the oracle passes in CI on every example with a fixture; the report is committed under `bench/decisions`.
7. **Later: observed effects for review** (Q17). At the `contained` level, run a reviewed command first in an overlay (user namespace with overlayfs, as `try` does), show the human the list of changes, and apply or discard them. The network stays outside. Exit: a reviewed `make clean` shows its deletions before it runs.

Order: 1 and 2 first, since they are bugs and small. Then 3. Steps 4 and 5 are refactors that steps 1–3 make safer to do. Step 6 can start in parallel with 3 and should land before 4, so the refactor has its regression net.

### (c) The evaluation method

As in section 6:
- **The corpus:** commands with fixture workspaces and a label per property, drawn from the tests, NL2Bash, the benchmarks and the log (the log's part stays private).
- **The metrics:** false-safe rate held at zero, review burden reported beside it, and an expected cost from an asymmetric matrix as the gate.
- **The model:** evaluated as review against forbidden only.
- **The oracle:** runs each command in a throwaway workspace, undoes it and compares, then runs it twice and compares. It is the ground truth for undoability and repeatability.
- **Property tests:** totality, monotonicity and coverage.
- **Mutation testing:** keeps every flag case pinned by an example.
