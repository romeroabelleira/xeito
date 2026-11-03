#!/usr/bin/env bash
# P4h step 6: builds the three busywork workspaces for bench/scripts/p4h_scripts.exs under DIR,
# and writes DIR/tasks.json for it. Real material: the req package as fetched into deps/ (its
# TODO comments), the failed-step logs of three CI runs of elixir-lang/elixir (`gh run view
# --log-failed`; GitHub keeps them for 90 days), and twelve open issues of the same repository.
#
#   bench/scripts/p4h_workspaces.sh DIR
set -euo pipefail
dir=${1:?usage: p4h_workspaces.sh DIR}
here=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$dir/todos" "$dir/ci-logs/ci-logs" "$dir/issues"

cp -r "$here/deps/req/." "$dir/todos/"
rm -rf "$dir/todos/.git"
todos=$(cd "$dir/todos" && rg -n 'TODO|FIXME' lib | cut -d: -f1,2 | sed 's/.*/"&"/' | paste -sd, -)

for id in 40711049974 41242941984 40948708714; do
  gh run view "$id" -R elixir-lang/elixir --log-failed > "$dir/ci-logs/ci-logs/run-$id.log"
done

gh issue list -R elixir-lang/elixir --state open --limit 12 --json number,title,body > "$dir/issues/issues.json"
issues=$(python3 -c 'import json,sys; print(",".join("\"%d\"" % i["number"] for i in json.load(open(sys.argv[1]))))' "$dir/issues/issues.json")

cat > "$dir/tasks.json" <<EOF
[
  {"id": "todos", "workspace": "$dir/todos",
   "request": "Find every TODO and FIXME comment under lib/ and classify each by urgency (low, medium or high) from what it says and the code around it. Answer with a markdown table: file:line, the comment, urgency.",
   "check": {"kind": "mentions", "all": [$todos]}},
  {"id": "ci_logs", "workspace": "$dir/ci-logs",
   "request": "The directory ci-logs holds the failed-step logs of three CI runs of the Elixir compiler (GitHub Actions; each line starts with the job's name). Group the failures by cause: for each cause, name the failing test or step, and which runs and jobs it hit. A log may show no failure at all; say so. Answer in markdown.",
   "check": {"kind": "mentions", "all": ["Map.update!/3", "to_existing_atom", "custom shutdown"]}},
  {"id": "issues", "workspace": "$dir/issues",
   "request": "issues.json holds twelve open issues of elixir-lang/elixir (number, title, body). Rate the clarity of each from 1 (unclear) to 3 (clear: what happens, what was expected, how to reproduce it), with a one-line reason. Answer with a markdown table: number, rating, reason.",
   "check": {"kind": "rated", "ids": [$issues], "range": [1, 3]}}
]
EOF
echo "$dir/tasks.json"
