# Deployment examples

Example service definitions for the [reference deployment](../docs/architecture/09-reference-deployment.md). They contain placeholders only. Keep your concrete paths, keys and host settings in your own private configuration.

| File | Service | Default bind |
|---|---|---|
| `systemd/xeito-llama-small.service.example` | llama.cpp `llama-server` on the CPU (small-gen tier) | `127.0.0.1:8081` |

The System One tier runs upstream [Laya](https://github.com/NandhaKishorM/laya) with its own `compose.yaml` and `compose.http.yaml`. An override publishes it on `127.0.0.1:8082`, sets `LAYA_MODELS=multilingual` and mounts an API key file (`LAYA_API_KEY_FILE`).
