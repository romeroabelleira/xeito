#!/usr/bin/env bash
# Pre-push mutation gate (test/support/xeito/mutate.ex): for each ref being pushed, run
# `mix xeito.mutate` on the sources of test/mutate.exs that changed since the commit the remote
# already has (or whose tests did), and refuse the push if a mutant survives. The nightly CI run
# mutates every source; `mix ci` does too.
#
# Called by git as the pre-push hook: `$1` is the remote's name, `$2` its URL, and stdin holds one
# line per ref: `<local ref> <local sha> <remote ref> <remote sha>`.
#
# Skips, with a note: a deleted ref; a machine without Elixir (the commit was checked where it was
# pushed from); a commit this gate already passed (pushing it to a second remote, such as GitHub
# after the bare repository, does not mutate twice).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

zero='0000000000000000000000000000000000000000'
remote="${1:-origin}"
marker="$(git rev-parse --path-format=absolute --git-common-dir)/xeito-mutated"

if ! command -v mix > /dev/null 2>&1; then
  echo "· mutation gate: mix is not available here; the commit was checked where it was pushed from." >&2
  exit 0
fi

# The tests run git in repositories of their own (see scripts/check-crap.sh).
unset $(git rev-parse --local-env-vars) \
  GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

# The commit to compare with: what the remote has, else where the pushed commit left the remote's
# main, else nothing (every source is mutated).
base_of() { # local sha, remote sha
  if [ "$2" != "$zero" ]; then
    echo "$2"
  elif git rev-parse -q --verify "refs/remotes/$remote/main" > /dev/null 2>&1; then
    git merge-base "$1" "refs/remotes/$remote/main" || true
  fi
}

while read -r _local_ref local_sha _remote_ref remote_sha; do
  [ "$local_sha" = "$zero" ] && continue

  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$local_sha" ]; then
    echo "✓ mutation gate: ${local_sha:0:7} passed already" >&2
    continue
  fi

  base="$(base_of "$local_sha" "$remote_sha")"
  if [ -n "$base" ]; then
    echo "· mutation gate: the sources changed since ${base:0:7}" >&2
    env="XEITO_MUTATE=changed XEITO_MUTATE_BASE=$base"
  else
    echo "· mutation gate: no common commit with $remote, every source" >&2
    env="XEITO_MUTATE=all"
  fi

  if out=$(env MIX_ENV=test $env mix xeito.mutate 2>&1); then
    echo "$out" | grep -E 'mutants,|nothing changed' >&2 || true
    echo "✓ mutation gate" >&2
    echo "$local_sha" > "$marker"
  else
    echo "$out" | grep -vE '^tests: ' | tail -40 >&2
    echo "✗ push refused: a mutant survived (or its tests failed); see above." >&2
    exit 1
  fi
done
