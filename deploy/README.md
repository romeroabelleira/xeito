# Deployment examples

Example service definitions for the [reference deployment](../docs/architecture/09-reference-deployment.md). They contain placeholders only. Keep your concrete paths, keys and host settings in your own private configuration.

| File | Service | Default bind |
|---|---|---|
| `systemd/xeito-llama-small.service.example` | llama.cpp `llama-server` on the CPU (small-gen tier) | `127.0.0.1:8081` |
| `systemd/xeitod.service.example` | the Xeito daemon: runs, logs, client API | Unix socket `~/.xeito/run/xeito.sock` |

The System One tier runs upstream [Laya](https://github.com/NandhaKishorM/laya) with its own `compose.yaml` and `compose.http.yaml`. An override publishes it on `127.0.0.1:8082`, sets `LAYA_MODELS=multilingual` and mounts an API key file (`LAYA_API_KEY_FILE`).

The daemon unit lowers its CPU weight and niceness and caps its memory. Every command the agent runs is a child of the daemon, so builds and test runs started by Xeito yield to interactive desktop use as well. Set `XEITO_KEEP_ALIVE` (for example `5m`) to control how long Ollama keeps the large model in VRAM after the last request.

Install a unit once with `cp -n` (as each file's header shows), then edit the installed copy. A plain `cp` over an installed unit replaces it, and when that unit is a symlink to your private configuration, it replaces your private file through the link.
