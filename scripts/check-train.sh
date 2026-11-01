#!/usr/bin/env bash
# ============================================================
# O v4 — check-train.sh  (merge train, o#22)
# ============================================================
#
# Boots swarmd with O_TRAIN=1 on a throwaway DB + random port, against a bare
# repo standing in for GitHub (gh stub) and a stub reviewer, and drives:
#   1. four approved docs PRs board one train: one train PR, CI runs once,
#      all four issues Done, main gets ONE merge commit carrying all four;
#      a runtime-tier PR approved alongside never boards
#   2. one of four PRs breaks the full CI (the stub fails `build` on any
#      branch holding its file): the train splits, the other three merge, the
#      bad one goes back to its builder with red_ci, and main never holds it
# Run by `make check` after scripts/check.sh; needs bin/swarmd built.
set -euo pipefail

export O_TICK_MS="${O_TICK_MS:-500}" O_BACKOFF_MS="${O_BACKOFF_MS:-300}"
export O_ADAPT=0 SW_SCHEDULERS="${SW_SCHEDULERS:-16}" O_BROKEN_RUNS=0 O_PREFLIGHT=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -x bin/swarmd ] || { echo "FAIL: bin/swarmd not built (make first)"; exit 1; }

DPID=""
T="$(mktemp -d)"
cleanup() {
  if [ -n "$DPID" ]; then kill "$DPID" 2>/dev/null || true; wait "$DPID" 2>/dev/null || true; fi
  if [ -n "${O_KEEP_TMP:-}" ]; then echo "kept: $T" >&2; else rm -rf "$T" 2>/dev/null || true; fi
}
trap cleanup EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }
sqlite3() { command sqlite3 -cmd ".timeout 5000" "$@"; }
ocurl() { curl --max-time 10 "$@" || curl --max-time 10 "$@"; }
jget() { printf '%s' "$1" | python3 -c "import sys,json;d=json.load(sys.stdin);print($2)"; }
free_port() {
  for _i in $(seq 1 50); do
    p=$(($1 + RANDOM % $2))
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; return 0; }
  done
  echo $(($1 + RANDOM % $2))
}
wait_status() {  # <iid> <status> <seconds>
  local st=""
  for _i in $(seq 1 "$3"); do
    st="$(jget "$(ocurl -s "$BASE/api/issues/$1")" 'd["status"]' 2>/dev/null || true)"
    [ "$st" = "$2" ] && return 0
    sleep 1
  done
  echo "  last status of $1: ${st:-none}"; return 1
}
diag() {
  echo "--- remote main:"; git -C "$GHS/remote.git" log --oneline --graph main | head -40
  echo "--- PRs:"; for f in "$GHS"/pr_*; do echo "$(basename "$f") $(cat "$f")"; done
  echo "--- train activity:"; sqlite3 "$T/o.db" "SELECT verb, target, payload FROM activity WHERE verb LIKE 'train.%' ORDER BY ts"
  grep -v "\[orch\] tick" "$T/daemon.log" | tail -30
}

GHS="$T/ghs"; mkdir -p "$GHS"; echo '[]' > "$GHS/issues.json"

# Reviewer stub: every review and gate approves, having "run" a command.
cat > "$T/claude-stub" <<'STUB'
#!/bin/sh
in="$(cat)"
case "$in" in
  *"== Review PR #"*)
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"make test"}}]}}'
    printf '{"type":"result","result":"Reviewed.\\nVERDICT: APPROVE","total_cost_usd":0.01,"session_id":"gate-%s"}\n' "$$"
    exit 0 ;;
esac
printf '%s' '{"type":"result","result":"Looked at it.\nVERDICT: APPROVE","total_cost_usd":0.01}'
STUB
chmod +x "$T/claude-stub"

# gh stub (`gh api` against a bare repo). Check runs: `lint` always passes
# (the docs tier's quick check); `build` (the full check) fails on a branch
# that holds any file listed in $GHS/fail_ci_file. PR numbers map to branches
# through $GHS/pr_<n>, titles through $GHS/title_<n>; every check-runs call
# is logged in $GHS/ci.log as "<branch> <sha>".
cat > "$T/gh-stub" <<'STUB'
#!/bin/sh
[ "$1" = "api" ] || { echo "gh-stub: only 'gh api' is supported" >&2; exit 2; }
exec 9>"$GHS/.lock"; flock 9
shift
method=GET; path=""; head=""; bodyf=""; newstate=""; ititle=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    -f|-F) case "$2" in head=*) head="${2#head=}" ;; body=@*) bodyf="${2#body=@}" ;; state=*) newstate="${2#state=}" ;; title=*) ititle="${2#title=}" ;; esac; shift ;;
    *) path="$1" ;;
  esac
  shift
done
num_for() { grep -lx "$1" "$GHS"/pr_* 2>/dev/null | head -1 | sed 's|.*/pr_||'; }
echo "$method $path" >> "$GHS/calls.log"
case "$method $path" in
  "GET repos/acme/widgets/issues?"*) cat "$GHS/issues.json" ;;
  "GET repos/acme/widgets/issues/comments"*) echo '[]' ;;
  "GET repos/acme/widgets/issues/"[0-9]*) echo "{\"number\":${path#repos/acme/widgets/issues/},\"state\":\"open\"}" ;;
  "POST repos/acme/widgets/issues/"*/comments)
    n="${path#repos/acme/widgets/issues/}"; n="${n%/comments}"; cat "$bodyf" >> "$GHS/comments_$n"; echo >> "$GHS/comments_$n"; echo '{"id":1}' ;;
  "GET repos/acme/widgets/pulls?head="*)
    b="${path#*head=acme:}"; b="${b%%&*}"; n="$(num_for "$b")"
    ma=""; [ -n "$n" ] && [ -f "$GHS/merged_$n" ] && ma=',"merged_at":"2026-01-01T00:00:00Z"'
    shut=""; [ -n "$n" ] && { [ -f "$GHS/closed_$n" ] || [ -f "$GHS/merged_$n" ]; } && shut=1
    case "$path" in *state=open*) [ -n "$shut" ] && n="" ;; *state=closed*) [ -z "$shut" ] && n="" ;; esac
    if [ -n "$n" ]; then echo "[{\"number\":$n$ma}]"; else echo "[]"; fi ;;
  "POST repos/acme/widgets/pulls")
    n=$(( $(ls "$GHS" | grep -c '^pr_') + 1 )); echo "$head" > "$GHS/pr_$n"; printf '%s\n' "$ititle" > "$GHS/title_$n"
    echo "{\"number\":$n}" ;;
  "PUT repos/acme/widgets/pulls/"*/merge)
    n="${path#repos/acme/widgets/pulls/}"; n="${n%/merge}"; b="$(cat "$GHS/pr_$n")"
    tmp="$(mktemp -d)"; git clone -q "$GHS/remote.git" "$tmp/c" && cd "$tmp/c" \
      && git -c user.email=gh@x -c user.name=gh merge -q --no-ff --no-edit "origin/$b" \
      && git push -q origin main && touch "$GHS/merged_$n" \
      && echo "{\"merged\":true,\"sha\":\"$(git rev-parse HEAD)\"}" ;;
  "PATCH repos/acme/widgets/pulls/"*)
    n="${path#repos/acme/widgets/pulls/}"; [ "$newstate" = closed ] && touch "$GHS/closed_$n"
    [ "$newstate" = open ] && rm -f "$GHS/closed_$n"
    echo "{\"number\":$n}" ;;
  "GET repos/acme/widgets/compare/"*)
    spec="${path#repos/acme/widgets/compare/}"; cbase="${spec%%...*}"; csha="${spec#*...}"
    nb="$(git -C "$GHS/remote.git" rev-list --count "$csha..$cbase" 2>/dev/null || echo 0)"; echo "{\"behind_by\":$nb}" ;;
  "PUT repos/acme/widgets/pulls/"*/update-branch)
    n="${path#repos/acme/widgets/pulls/}"; n="${n%/update-branch}"; b="$(cat "$GHS/pr_$n")"
    tmp="$(mktemp -d)"; git clone -q "$GHS/remote.git" "$tmp/c" && cd "$tmp/c" && git checkout -q "$b" \
      && git -c user.email=gh@x -c user.name=gh merge -q --no-edit origin/main && git push -q origin "$b"
    echo '{"message":"Updating pull request branch."}' ;;
  "DELETE repos/acme/widgets/git/refs/heads/"*) git -C "$GHS/remote.git" branch -q -D "${path#repos/acme/widgets/git/refs/heads/}" 2>/dev/null; echo '{}' ;;
  "GET repos/acme/widgets/pulls/"*/files*)
    n="${path#repos/acme/widgets/pulls/}"; n="${n%%/files*}"; b="$(cat "$GHS/pr_$n")"
    git -C "$GHS/remote.git" diff --name-only "main...$b" | python3 -c 'import json,sys;print(json.dumps([{"filename":l.strip()} for l in sys.stdin if l.strip()]))' ;;
  "GET repos/acme/widgets/pulls/"*)
    n="${path#repos/acme/widgets/pulls/}"; b="$(cat "$GHS/pr_$n")"
    sha="$(git -C "$GHS/remote.git" rev-parse "refs/heads/$b" 2>/dev/null)"; echo "$b" > "$GHS/sha_$sha"
    m=false; st=open; [ -f "$GHS/merged_$n" ] && { m=true; st=closed; }; [ -f "$GHS/closed_$n" ] && st=closed
    echo "{\"number\":$n,\"state\":\"$st\",\"merged\":$m,\"mergeable_state\":\"clean\",\"head\":{\"sha\":\"$sha\",\"ref\":\"$b\"}}" ;;
  "GET repos/acme/widgets/commits/"*/check-runs*)
    sha="${path#repos/acme/widgets/commits/}"; sha="${sha%%/*}"; b="$(cat "$GHS/sha_$sha" 2>/dev/null)"
    n="$(num_for "$b")"; c=success
    echo "$b $sha" >> "$GHS/ci.log"
    if [ -f "$GHS/fail_ci_file" ]; then
      while read -r f; do [ -n "$f" ] && git -C "$GHS/remote.git" cat-file -e "$sha:$f" 2>/dev/null && c=failure; done < "$GHS/fail_ci_file"
    fi
    du="https://github.com/acme/widgets/actions/runs/$n/job/1"
    echo "{\"check_runs\":[{\"name\":\"lint\",\"status\":\"completed\",\"conclusion\":\"success\",\"details_url\":\"$du\"},{\"name\":\"build\",\"status\":\"completed\",\"conclusion\":\"$c\",\"details_url\":\"$du\"}]}" ;;
  "POST repos/acme/widgets/actions/runs/"*/rerun-failed-jobs) echo '{}' ;;
  "GET repos/acme/widgets/commits/"*/status) echo '{"state":"success","statuses":[]}' ;;
  *) echo "gh-stub: unhandled $method $path" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/gh-stub"

# The project: docs/ is an auto-merge tier with a quick `lint` check; risky/
# is the runtime tier, merged by a human. The full CI is `build`.
git init -q --bare -b main "$GHS/remote.git"
SEED="$T/seed"; git clone -q "$GHS/remote.git" "$SEED" 2>/dev/null
git -C "$SEED" config user.email "o@example.com"; git -C "$SEED" config user.name "O Test"
printf '#!/bin/sh\nexit 0\n' > "$SEED/verify.sh"; echo "train project" > "$SEED/README.md"
cat > "$SEED/.o-review.json" <<'JSON'
{ "build": "true",
  "suite": "true",
  "required_checks": ["build"],
  "tiers": [ { "name": "docs", "paths": ["docs/"], "merge": "auto", "required_checks": ["lint"], "gate_model": "sonnet" },
             { "name": "runtime", "paths": ["risky/"], "merge": "human" } ] }
JSON
git -C "$SEED" add -A; git -C "$SEED" commit -q -m "seed train project"; git -C "$SEED" push -q origin main 2>/dev/null
REPO="$T/clone"; git clone -q "$GHS/remote.git" "$REPO"
git -C "$REPO" config user.email "o@example.com"; git -C "$REPO" config user.name "O Test"

PORT="$(free_port 6300 300)"; BASE="http://127.0.0.1:$PORT"
HOME="$T" O_DB="$T/o.db" O_PORT="$PORT" O_NO_OPEN=1 O_REVIEW=1 O_MERGE_GATE=1 O_CLAUDE_BIN="$T/claude-stub" \
  O_GH_BIN="$T/gh-stub" GHS="$GHS" O_GH_POLL_S=2 O_CI_POLL_S=1 O_CI_SETTLE_S=0 O_POSTMERGE_S=0 O_AUTO_FILE=0 \
  O_TRAIN=1 O_TRAIN_MAX=4 O_TRAIN_INTERVAL_S=600 \
  ./bin/swarmd >"$T/daemon.log" 2>&1 &
DPID=$!
up=""
for _i in $(seq 1 30); do
  [ "$(ocurl -s -o /dev/null -w '%{http_code}' "$BASE/api/health" 2>/dev/null || true)" = "200" ] && { up=1; break; }
  sleep 0.5
done
[ -n "$up" ] || { cat "$T/daemon.log"; fail "train: daemon never came up"; }

CID="$(jget "$(ocurl -s -X POST "$BASE/api/companies" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Train Co\",\"issue_prefix\":\"TR\",\"budget_monthly_cents\":1000000,\"repo\":\"$REPO\",\"verify_cmd\":\"sh verify.sh\",\"github_repo\":\"acme/widgets\",\"ship\":\"pr\"}")" 'd["id"]')"
issue() { jget "$(ocurl -s -X POST "$BASE/api/companies/$CID/issues" -H 'Content-Type: application/json' -d "{\"title\":\"$1\"}")" 'd["id"]'; }
pr_of() { grep -lx "o/$1" "$GHS"/pr_* | head -1 | sed 's|.*/pr_||'; }
trains_opened() { grep -l '^o/train-' "$GHS"/pr_* 2>/dev/null | wc -l | tr -d ' '; }

# ---- 1. four docs PRs, one train; a runtime PR never boards ------------
A1="$(issue '[sim:docs] train docs a')"; A2="$(issue '[sim:docs] train docs b')"
A3="$(issue '[sim:docs] train docs c')"; A4="$(issue '[sim:docs] train docs d')"
RK="$(issue '[sim:risky] runtime internals')"
ocurl -s -X POST "$BASE/api/companies/$CID/agents" -H 'Content-Type: application/json' -d '{"name":"Trainsim","runtime":"sim"}' >/dev/null
for i in "$A1" "$A2" "$A3" "$A4"; do
  wait_status "$i" Done 240 || { diag; fail "train: approved docs PR $i never Done"; }
done
[ "$(trains_opened)" = "1" ] || { diag; fail "train: expected one train PR, got $(trains_opened)"; }
TPR="$(grep -l '^o/train-' "$GHS"/pr_* | sed 's|.*/pr_||')"; TB="$(cat "$GHS/pr_$TPR")"
grep "^O merge train #[0-9]*: PRs #" "$GHS/title_$TPR" >/dev/null || fail "train: train PR title is '$(cat "$GHS/title_$TPR")'"
for i in "$A1" "$A2" "$A3" "$A4"; do
  n="$(pr_of "$i")"
  grep -F "#$n" "$GHS/title_$TPR" >/dev/null || fail "train: PR #$n missing from the train title"
  [ -f "$GHS/merged_$n" ] && fail "train: member PR #$n merged on its own"
  [ -f "$GHS/closed_$n" ] || fail "train: member PR #$n not closed"
  grep "merged in train #" "$GHS/comments_$n" >/dev/null || fail "train: member PR #$n has no 'merged in train' comment"
done
[ -f "$GHS/merged_$TPR" ] || fail "train: the train PR was not merged"
# CI ran once for the batch: one train head checked, and no other train
[ "$(grep '^o/train-' "$GHS/ci.log" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')" = "1" ] || { cat "$GHS/ci.log"; fail "train: CI ran on more than one train head"; }
# one merge commit on main carrying all four changes
MC="$(git -C "$GHS/remote.git" log --first-parent --merges --format=%H main | head -1)"
[ "$(git -C "$GHS/remote.git" log --first-parent --merges --format=%H main | wc -l | tr -d ' ')" = "1" ] || { diag; fail "train: main should have exactly one merge commit"; }
for i in "$A1" "$A2" "$A3" "$A4"; do
  git -C "$GHS/remote.git" diff --name-only "$MC^1" "$MC" | grep -x "docs/d_$i.md" >/dev/null || { diag; fail "train: the merge commit lacks docs/d_$i.md"; }
done
git -C "$GHS/remote.git" log --format=%s "$MC^1..$MC" | grep "into merge train" >/dev/null || fail "train: the members' merge commits are not visible on main"
for v in train.start train.merged; do
  [ "$(sqlite3 "$T/o.db" "SELECT COUNT(*) FROM activity WHERE verb='$v'")" = "1" ] || { diag; fail "train: expected one $v"; }
done
tr="$(ocurl -s "$BASE/api/companies/$CID/trains")"
echo "$tr" | python3 -c '
import json,sys
t=json.load(sys.stdin)
assert len(t)==1 and t[0]["state"]=="merged" and len(t[0]["members"])==4, t
' || fail "train: /api/companies/:id/trains does not show the merged train and its 4 members: $tr"
ocurl -s "$BASE/api/snapshot" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert len(d["trains"])==1 and len(d["trains"][0]["members"])==4, d["trains"]
' || fail "train: /api/snapshot does not carry the train and its members"
pass "train: 4 approved docs PRs board one train, CI runs once, all Done, one merge commit on main carries all 4"
wait_status "$RK" "In Review" 120 || { diag; fail "train: the runtime-tier PR did not park for a human"; }
[ "$(sqlite3 "$T/o.db" "SELECT COUNT(*) FROM activity WHERE verb='train.board' AND target='$RK'")" = "0" ] || fail "train: a runtime-tier PR boarded"
grep -lx "o/$RK" "$GHS"/pr_* >/dev/null || fail "train: the runtime-tier PR never got its own PR"
pass "train: a runtime-tier PR never boards; it waits for a human on its own PR"

# ---- 2. one bad PR of four: split, three merge, it goes back -----------
B1="$(issue '[sim:docs] second train a')"; B2="$(issue '[sim:docs] second train b')"
B3="$(issue '[sim:docs] second train breaks CI')"; B4="$(issue '[sim:docs] second train d')"
echo "docs/d_$B3.md" > "$GHS/fail_ci_file"
for i in "$B1" "$B2" "$B4"; do
  wait_status "$i" Done 300 || { diag; fail "train: a good PR in the red train never merged"; }
done
for _i in $(seq 1 60); do
  [ "$(sqlite3 "$T/o.db" "SELECT COUNT(*) FROM run WHERE issue_id='$B3' AND verify_state='red_ci'")" -ge 1 ] && break; sleep 1
done
vo="$(sqlite3 "$T/o.db" "SELECT verify_output FROM run WHERE issue_id='$B3' AND verify_state='red_ci' ORDER BY started_at LIMIT 1")"
echo "$vo" | grep "merge train" >/dev/null && echo "$vo" | grep "build" >/dev/null || { diag; fail "train: the bad PR did not get red_ci naming the failing check (got: $vo)"; }
for _i in $(seq 1 60); do
  [ "$(sqlite3 "$T/o.db" "SELECT COUNT(*) FROM activity WHERE verb='run.dispatch' AND target='$B3'")" -ge 2 ] && break; sleep 1
done
[ "$(sqlite3 "$T/o.db" "SELECT COUNT(*) FROM activity WHERE verb='run.dispatch' AND target='$B3'")" -ge 2 ] || fail "train: the bad PR did not go back to its builder"
[ "$(sqlite3 "$T/o.db" "SELECT COUNT(*) FROM activity WHERE verb='train.split'")" -ge 1 ] || { diag; fail "train: the red train did not split"; }
[ "$(sqlite3 "$T/o.db" "SELECT COUNT(*) FROM activity WHERE verb='train.red'")" = "1" ] || { diag; fail "train: expected one one-PR train to go red"; }
[ "$(sqlite3 "$T/o.db" "SELECT status FROM issue WHERE id='$B3'")" != "Done" ] || fail "train: the bad PR was marked Done"
for c in $(git -C "$GHS/remote.git" rev-list --first-parent main); do
  git -C "$GHS/remote.git" cat-file -e "$c:docs/d_$B3.md" 2>/dev/null && { diag; fail "train: main went red (holds the bad PR's file at $c)"; }
done
for i in "$B1" "$B2" "$B4"; do
  git -C "$GHS/remote.git" cat-file -e "main:docs/d_$i.md" 2>/dev/null || fail "train: docs/d_$i.md not on main"
done
pass "train: a red train splits, 3 merge, the bad PR goes back to its builder with red_ci; main never goes red"
