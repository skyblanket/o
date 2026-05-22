#!/bin/sh
# Seed the self-hosting maintainer — a company whose claude-code agent
# works inside the O v4 repo itself, on an isolated branch per issue.
#
#   ./scripts/seed-maintainer.sh
#   O_REPO=/path/to/o ./scripts/seed-maintainer.sh
set -e

API="${O_API:-http://localhost:4100}"
REPO="${O_REPO:-$HOME/o}"

curl -s "$API/api/health" >/dev/null 2>&1 || { echo "error: daemon not reachable at $API"; exit 1; }
[ -d "$REPO/.git" ] || { echo "error: $REPO is not a git repo (set O_REPO)"; exit 1; }
extract_id() { sed -n 's/.*"id":"\([^"]*\)".*/\1/p'; }

CO=$(curl -s -X POST "$API/api/companies" \
  -d '{"name":"O v4 Core","mission":"keep O v4 healthy and improving","issue_prefix":"CORE","budget_monthly_cents":200000}' \
  | extract_id)
echo "company   O v4 Core  ($CO)"

curl -s -X POST "$API/api/companies/$CO/agents" \
  -d "{\"name\":\"Maintainer\",\"role\":\"engineer\",\"runtime\":\"claude-code\",\"repo\":\"$REPO\"}" >/dev/null
echo "agent     Maintainer  (claude-code · repo $REPO)"

echo
echo "done. File maintenance issues in 'O v4 Core' from the dashboard —"
echo "the Maintainer works each on branch o/<issue> in $REPO."
echo "review the branches:  git -C $REPO branch --list 'o/*'"
