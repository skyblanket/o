#!/bin/sh
# Seed the "O maintains O" dogfood company — a company whose claude-code
# agent works inside THIS repo, on an isolated git worktree per issue, and
# whose green work is verified by O's own test suite before it merges.
#
#   ./scripts/seed-maintainer.sh
#   O_REPO=/path/to/o O_DAILY=8000 ./scripts/seed-maintainer.sh
#
# ------------------------------------------------------------------
# Why verify_cmd is `make check` and why that is safe:
#
#   `make check` runs scripts/check.sh, which boots its OWN throwaway
#   daemon on a TEMP DB (mktemp) + a RANDOM port and drives the whole
#   REST pipeline against it. So when O verifies a change to O, the
#   verify run never binds :4100 and never touches the operator's live
#   ~/.o/o.db — O-verifying-O cannot collide with the running daemon.
#
#   `make check` also compiles the repo with swc, so the SWARMRT
#   toolchain must be resolvable from inside the per-issue worktree
#   (~/.o/workspaces/<issue>). The Makefile default `../swarmrt` does
#   NOT resolve from a worktree, so the daemon that runs this company
#   must be started with SWARMRT exported to an ABSOLUTE path, e.g.
#
#       SWARMRT=/abs/path/to/swarmrt swarmd
#
#   That env is inherited by the verify command in every worktree.
#
#   protected_paths keeps the loop honest: an agent may not edit the
#   test harness (scripts/check.sh) or the frozen invariants
#   (tests/heldout/) that gate its own merges.
# ------------------------------------------------------------------
set -e

API="${O_API:-http://localhost:4100}"
REPO="${O_REPO:-$(pwd)}"
DAILY="${O_DAILY:-5000}"

curl -s "$API/api/health" >/dev/null 2>&1 || { echo "error: daemon not reachable at $API"; exit 1; }
[ -d "$REPO/.git" ] || { echo "error: $REPO is not a git repo (set O_REPO)"; exit 1; }
extract_id() { sed -n 's/.*"id":"\([^"]*\)".*/\1/p'; }

CO=$(curl -s -X POST "$API/api/companies" \
  -d "{\"name\":\"O Core\",\"mission\":\"keep O healthy and improving\",\"issue_prefix\":\"CORE\",\"repo\":\"$REPO\",\"verify_cmd\":\"make check\",\"protected_paths\":\"scripts/check.sh,tests/heldout/\",\"budget_daily_cents\":$DAILY,\"budget_monthly_cents\":200000}" \
  | extract_id)
echo "company   O Core  ($CO)"
echo "          repo=$REPO  verify='make check'  daily=${DAILY}c"
echo "          protected=scripts/check.sh,tests/heldout/"

curl -s -X POST "$API/api/companies/$CO/agents" \
  -d "{\"name\":\"Maintainer\",\"role\":\"engineer\",\"runtime\":\"claude-code\",\"repo\":\"$REPO\"}" >/dev/null
echo "agent     Maintainer  (claude-code · repo $REPO)"

echo
echo "done. File maintenance issues in 'O Core' from the dashboard —"
echo "the Maintainer works each on branch o/<issue> in $REPO, and its"
echo "changes merge only if 'make check' stays green."
echo "review the branches:  git -C $REPO branch --list 'o/*'"
