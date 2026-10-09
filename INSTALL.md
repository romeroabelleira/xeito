# Installing Xeito

How to build Xeito from source, connect it to models, and run its daemon as a service. Once it runs, [USAGE.md](USAGE.md) shows how to work with it.

> Xeito is pre-release software and runs from a source checkout. A packaged release and an installer are planned for P8 ([implementation plan](docs/implementation-plan.md)).

## 1. Requirements

| What | Why |
|---|---|
| Linux, or macOS | The reference deployment is a Linux workstation with systemd ([09](docs/architecture/09-reference-deployment.md)). On macOS everything runs, but no service definition is provided. |
| Erlang/OTP and Elixir, at the versions in `.tool-versions` | Xeito is an Elixir/OTP application. [mise](https://mise.jdx.dev) or asdf installs the pinned versions. |
| A C and C++ compiler, and `make` | Two dependencies build native code with the others: SQLite for the event log (`exqlite`), and erlexec's port program, which runs shell commands so they can be stopped with everything they start. On Debian or Ubuntu: `sudo apt install build-essential`. On macOS: `xcode-select --install`. |
| git | `/undo` and `/redo` snapshot the workspace with git, and the `commit` machine commits with it. |
| A model server for the `local` tier | [Ollama](https://ollama.com), on a GPU that holds the chat model. Without a model, the daemon still runs commands and machines that need none (`/run`), and every decision abstains. |
| Optional: mise in your projects | A command runs with the tool versions its workspace pins with mise ([USAGE](USAGE.md)). |

## 2. Build

```bash
git clone <the repository URL> xeito
cd xeito
mise install        # Erlang/OTP and Elixir from .tool-versions
mix deps.get
mix compile         # also builds SQLite and erlexec's port program
mix test            # optional: the whole suite, about a minute
```

## 3. Models

Tiers are places on the escalation ladder, named by the kind of model and where it runs:

| Tier | Kind | Default backend |
|---|---|---|
| `local_decision` | a System One decision model on this machine (`laya-serve`) | `system_one` |
| `remote_decision` | a hosted System One decision model (Jev) | `system_one` |
| `local` | the language model on the local GPU: the chat model, and the decider of every built-in decision type | `ollama` |
| `remote` | a hosted language model with logprobs, so its confidence is calibrated | `openrouter` |
| `remote_frontier` | the strongest hosted language model; it answers without a confidence, terminally | `openrouter` |

A practical minimum is the `local` tier alone: install Ollama, pull a model that fits your GPU (the [reference deployment](docs/architecture/09-reference-deployment.md#tier-local-gpu) explains the choice), and point Xeito at it.

```bash
ollama pull qwen3.6:27b
```

### Model tiers

Each tier reads the same variables under its own prefix, `XEITO_<TIER>_`, when the daemon starts (`Xeito.Tiers.Settings`). A tier that is not configured is not used.

| Variable (for `XEITO_LOCAL_…`; the same for every tier) | Meaning | Example |
|---|---|---|
| `XEITO_LOCAL_URL` | the backend's address; a local tier is configured by it | `http://127.0.0.1:11434` |
| `XEITO_LOCAL_MODEL` | the model | `qwen3.6:27b` |
| `XEITO_LOCAL_KEY_FILE` | a file holding the backend's API key | `~/.config/xeito/laya_api_key` |
| `XEITO_LOCAL_BACKEND` | the API the tier speaks: `ollama`, `openrouter` or `system_one` | (the tier's default) |
| `XEITO_LOCAL_CONTEXT` | Ollama: the context window in tokens, sent as `num_ctx` with every request; the chat machine fits its requests into it | `65536` (unset: the server's setting, and a 32768 budget) |
| `XEITO_LOCAL_KEEP_ALIVE` | Ollama: how long the model stays in VRAM after the last request | `5m` (default `10m`) |
| `XEITO_REMOTE_PROVIDERS`, `XEITO_REMOTE_ZDR` | OpenRouter: providers to pin (comma list); `false` to allow endpoints that retain prompts | `Parasail`; default on |

**Remote tiers are opt-in.** A remote tier is configured only when its model and its key file are both set; an OpenRouter tier's URL defaults to OpenRouter's. One OpenRouter key file can serve both `remote` and `remote_frontier`, but each needs its own `…_MODEL` and `…_KEY_FILE`. Even configured, a remote tier is reached only where the decision's policy allows off-box tiers ([guards on escalation](docs/architecture/04-delegation.md#guards-on-escalation); [spend limits](USAGE.md#spend-limits)). `remote_decision` has no default URL, since no hosted System One model is reachable through OpenRouter.

**Keys are never put in variables.** The `*_KEY_FILE` variables name a file that contains only the key, with mode 0600. For example, with the 1Password CLI:

```bash
op read "op://Private/OpenRouter/credential" > ~/.config/xeito/openrouter.key && chmod 600 ~/.config/xeito/openrouter.key
```

Keep the variables in one file that both your shell and the service source:

```bash
# ~/.config/xeito/tiers.env
export XEITO_LOCAL_URL=http://127.0.0.1:11434
export XEITO_LOCAL_MODEL=qwen3.6:27b
export XEITO_LOCAL_CONTEXT=65536
export XEITO_LOCAL_KEEP_ALIVE=5m
# Off-box, opt-in: uncomment to use a hosted model where policy allows it.
# export XEITO_REMOTE_MODEL=qwen/qwen3.8-27b
# export XEITO_REMOTE_KEY_FILE="$HOME/.config/xeito/openrouter.key"
```

## 4. Recommended local configuration

- **Set `XEITO_LOCAL_CONTEXT` to the context window your model really runs with.** Ollama does not refuse a prompt that is too long: it cuts it from the front, which drops the system prompt first, and reports no error. Xeito fits its requests into the window it is told about, and warns when the server cut one anyway.
- **Keep every model server on loopback.** Ollama binds to `127.0.0.1:11434` by default; check that its service configuration does not bind it to other interfaces. Reach a server from another machine through an SSH tunnel or a private VPN, never a port open on the LAN ([09 · Services](docs/architecture/09-reference-deployment.md#services)).
- **Choose `XEITO_LOCAL_KEEP_ALIVE`** by how you share the GPU: a few minutes frees VRAM for other work soon after a session goes quiet, at the cost of a reload (seconds) on the next request.
- **Budget CPU threads** when a decision model runs on the CPU next to a GPU model: [09 · Thread budget](docs/architecture/09-reference-deployment.md#thread-budget).
- **Work in git repositories.** Undo relies on git snapshots of the workspace; outside a repository there is nothing to undo with.
- **Trust your projects' mise configuration** (`mise trust` in the project) if they pin tools in a `mise.toml`; mise refuses to load an untrusted one, and Xeito reports that with the fix.
- **Skills** are read from `<project>/.agents/skills/` and `~/.agents/skills/` ([USAGE · Skills](USAGE.md#skills)). `XEITO_SKILL_KEYWORDS` names an optional file of extra keywords per skill.

Other paths Xeito uses:

| Path | What |
|---|---|
| `~/.xeito/run/xeito.sock` | the daemon's socket, in a private directory (0700); `XEITO_SOCKET` moves it |
| `~/.config/xeito/tiers.env` | your tier settings (the name is a convention; the service unit sources it) |
| `~/.config/xeito/tui.json` | the TUI's preferences; `$XDG_CONFIG_HOME` or `XEITO_TUI_CONFIG` moves it |
| `<project>/.xeito/` | the project's event log and its always-allowed commands (`allowed.json`), kept out of git by a `.gitignore` of its own |

## 5. Run the daemon

In a terminal, to try things out:

```bash
source ~/.config/xeito/tiers.env
mix xeito.daemon
```

### As a systemd user service (Linux)

[`deploy/systemd/xeitod.service.example`](deploy/systemd/xeitod.service.example) is a unit to start from. Install it once, with `cp -n` so that an existing unit (possibly a symlink to your own copy) is not replaced, set its two paths, and enable it:

```bash
cp -n deploy/systemd/xeitod.service.example ~/.config/systemd/user/xeitod.service
$EDITOR ~/.config/systemd/user/xeitod.service      # WorkingDirectory, and the path to mise
systemctl --user daemon-reload && systemctl --user enable --now xeitod
loginctl enable-linger "$USER"                      # start at boot, not only at login
journalctl --user -u xeitod -f
```

What its settings are for:

| Setting | Why |
|---|---|
| `KillMode=mixed` | A stop sends SIGTERM to the daemon alone, which then stops the commands it started, in order. With systemd's default, every process in the unit got SIGTERM at once, and erlexec's port program exited before the daemon could stop it, which it logged as an error. Anything still running when `TimeoutStopSec` ends gets SIGKILL. |
| `TimeoutStopSec=15` | A short stop is safe: runs recover from the log on the next start. |
| `Restart=on-failure` | The daemon comes back after a crash; sessions and runs are rebuilt from the logs. |
| `Nice`, `CPUWeight`, `IOScheduling…` | Desktop first. Every command the agent runs is a child of the daemon and shares its cgroup, so builds and test runs started by Xeito yield to your own work. |
| `MemoryHigh`, `MemoryMax`, `TasksMax` | A runaway command cannot take the machine down with it. Size them to your machine. |

`IOWeight` works only if the io controller is delegated to your user manager; the unit's last comment shows how to check.

### macOS

Run the daemon in a terminal. If you write a launchd agent for it, make sure a stop sends SIGTERM to the daemon process and waits for it, for the reason `KillMode=mixed` gives above.

## 6. Check that it works

`mix xeito` lists Xeito's tasks with a line on each, and every task explains itself with `--help`. Then open a session on a project:

```bash
mix xeito.tui --cwd ~/some/project      # or: mix xeito.chat --cwd ~/some/project (line mode)
```

In the TUI, `/help` lists the commands, `/machines` the machines, and `/run git status` runs a command without a model. A free-form question then goes to the chat model; if every decision says `abstain`, the daemon cannot reach a model tier ([troubleshooting](USAGE.md#12-troubleshooting)).

## 7. Updating

```bash
git pull
mix deps.get
mix compile
systemctl --user restart xeitod         # or stop and start mix xeito.daemon
```

A daemon keeps running the code it loaded at start. When its code changed on disk since, the first prompt of a session says so. Sessions and runs survive a restart: they are rebuilt from the logs, and a session continues where it was.

## 8. Uninstalling

Stop and remove the service (`systemctl --user disable --now xeitod`, then delete the unit), and delete the checkout. Your settings are in `~/.config/xeito/`, the socket directory is `~/.xeito/`, and each project you used keeps its log in `<project>/.xeito/`; delete those you no longer want.
