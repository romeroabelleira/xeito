#!/usr/bin/env bash
# Try a change by hand against a throwaway daemon: its own socket, its own TUI preferences, and a
# scratch workspace, so your real daemon, sessions and settings are never touched.
#
#   scripts/try-local.sh                  the TUI, in an empty scratch workspace
#   scripts/try-local.sh --cwd DIR        the TUI, in DIR (its session log goes to DIR/.xeito)
#   scripts/try-local.sh --chat           the line-mode client instead; reads stdin, so it also
#                                         scripts a smoke test:  echo /help | scripts/try-local.sh --chat
#   XEITO_TRY_KEEP=1 scripts/try-local.sh keep the scratch directory (daemon log, workspace)
#
# Model tiers come from the environment, as for `mix xeito.daemon`: source your tiers file first
# (USAGE.md, "Model tiers"). Without them, everything but model calls still works: the prompt
# line, slash commands, the status bar, `/run`.
set -euo pipefail
cd "$(dirname "$0")/.."

client=xeito.tui
cwd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --chat) client=xeito.chat ;;
    --cwd) cwd="$2"; shift ;;
    *) echo "usage: scripts/try-local.sh [--chat] [--cwd DIR]" >&2; exit 2 ;;
  esac
  shift
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/xeito-try.XXXXXX")
socket="$scratch/xeito.sock"
log="$scratch/daemon.log"
cwd="${cwd:-$scratch/workspace}"
mkdir -p "$cwd"
export XEITO_TUI_CONFIG="$scratch/tui.json"

# Compile once up front, so the daemon and the client do not both compile into _build.
mix compile >/dev/null

mix xeito.daemon --socket "$socket" >"$log" 2>&1 &
daemon=$!

cleanup() {
  kill "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  if [ "${XEITO_TRY_KEEP:-}" = 1 ]; then echo "kept $scratch" >&2; else rm -rf "$scratch"; fi
}
trap cleanup EXIT

for _ in $(seq 100); do
  [ -S "$socket" ] && break
  kill -0 "$daemon" 2>/dev/null || break
  sleep 0.1
done

if [ ! -S "$socket" ]; then
  echo "the daemon did not start:" >&2
  cat "$log" >&2
  exit 1
fi

mix "$client" --socket "$socket" --cwd "$cwd"
