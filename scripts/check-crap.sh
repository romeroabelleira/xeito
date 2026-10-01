#!/usr/bin/env bash
# Pre-commit CRAP gate (test/support/xeito/crap.ex): when Elixir code is staged, run the suite with
# coverage and refuse the commit if a function is above the CRAP maximum or worse than its
# baseline (or a test fails). Fails closed: without Elixir on this machine, Elixir changes cannot
# be checked here, so commit them where they can be. CI runs the same gate (`mix ci`).
#
# It checks the working tree, not only what is staged.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

if ! git diff --cached --name-only | grep -qE '\.(ex|exs)$|^mix\.(exs|lock)$'; then
  exit 0
fi

if ! command -v mix > /dev/null 2>&1; then
  echo "✗ CRAP gate: Elixir code is staged but mix is not available here; commit on a machine with Elixir." >&2
  exit 1
fi

if out=$(MIX_ENV=test mix test --cover 2>&1); then
  echo "✓ CRAP gate"
else
  echo "$out" | sed -n '/^Result:\|failure\|CRAP (max\|^\*\* (Mix)/,$p' | head -60 >&2
  echo "✗ commit refused: the CRAP gate (or the tests) failed; see above." >&2
  exit 1
fi
