#!/usr/bin/env bash
# ============================================================
# O — acceptance.sh   (end-to-end proof of the whole loop)
# ============================================================
#
# Drives the full self-improving loop against a REAL scratch project:
# an agent ships a change, it verifies + merges; a regression is caught
# and auto-reverted with a fix issue filed; self-file dedup holds; the
# budget circuit breaker pauses + rolls over; and the daily reflection
# pass files an improvement issue. Numbered stages, a PASS/FAIL matrix at
# the end, and a nonzero exit on any failure.
#
# Two modes for the "agent ships a change" stage:
#   default (STUB) — a deterministic `sim` agent + [sim:good] title. Fully
#                    hermetic, no tokens, safe to run in CI.
#   O_ACCEPT_REAL=1 — hire a real claude-code agent and give it a genuine
#                    task ("add a slugify function"). Needs claude on PATH
#                    (or O_CLAUDE_BIN). The operator runs this mode.
#
# Conventions mirror scripts/check.sh: throwaway daemon on a temp DB +
# random port, ocurl with a hard timeout + one retry, a trap that tears
# everything down on any exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="stub"
[ "${O_ACCEPT_REAL:-0}" = "1" ] && MODE="real"

DAEMON_PID=""; TMP=""
DAEMON2_PID=""; TMP2=""

cleanup() {
  for pid in "$DAEMON_PID" "$DAEMON2_PID"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
  for d in "$TMP" "$TMP2"; do
    if [ -n "$d" ]; then rm -rf "$d" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

# ---- PASS/FAIL matrix ----------------------------------------
declare -a MATRIX
CUR=""
stage() { CUR="$1"; echo; echo "==== $1 ===="; }
mark()  { MATRIX+=("$1|$2"); }
print_matrix() {
  echo
  echo "================= ACCEPTANCE MATRIX ================="
  local row st desc
  for row in "${MATRIX[@]}"; do
    st="${row%%|*}"; desc="${row#*|}"
    printf '  [ %-4s ]  %s\n' "$st" "$desc"
  done
  echo "===================================================="
}
ok()  { echo "  ok: $1"; }
pass_stage() { mark PASS "$CUR"; }
die() {
  echo "  FAIL: $1"
  mark FAIL "$CUR${1:+ — $1}"
  print_matrix
  exit 1
}

# curl with a hard cap + one retry on a dropped keep-alive (exit 52).
ocurl() {
  local out rc
  out="$(curl --max-time 10 "$@")"; rc=$?
  if [ "$rc" = "52" ]; then out="$(curl --max-time 10 "$@")"; rc=$?; fi
  printf '%s' "$out"; return "$rc"
}
jget() { printf '%s' "$1" | python3 -c "import sys,json;d=json.load(sys.stdin);print($2)"; }

# boot_daemon <homedir> <db> <port> [extra env kv...] -> sets DAEMON_PID
wait_health() {  # <base> <pid> <label>
  local up="" code
  for _i in $(seq 1 30); do
    if ! kill -0 "$2" 2>/dev/null; then cat "$3.log" 2>/dev/null || true; return 1; fi
    code="$(ocurl -s -o /dev/null -w '%{http_code}' "$1/api/health" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then up="1"; break; fi
    sleep 0.5
  done
  [ -n "$up" ]
}

wait_issue_status() {  # <base> <iid> <want> <max-seconds>
  local st=""
  for _i in $(seq 1 "$4"); do
    st="$(jget "$(ocurl -s "$1/api/issues/$2")" 'd["status"]' 2>/dev/null || true)"
    if [ "$st" = "$3" ]; then return 0; fi
    sleep 1
  done
  echo "  last status of $2: ${st:-none}"; return 1
}

# ============================================================
# Stage 1 — boot the hermetic daemon
# ============================================================
stage "stage 1: boot hermetic daemon"
[ -x "./bin/swarmd" ] || die "bin/swarmd missing — run make first"
TMP="$(mktemp -d)"
PORT=$((5600 + RANDOM % 300))
BASE="http://127.0.0.1:${PORT}"
# Real mode inherits the operator's O_CLAUDE_BIN / PATH so a genuine claude
# is reachable; stub mode never spawns claude, so nothing extra is needed.
HOME="$TMP" O_DB="$TMP/o.db" O_PORT="$PORT" O_NO_OPEN=1 \
  ./bin/swarmd >"$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!
wait_health "$BASE" "$DAEMON_PID" "$TMP/daemon" || die "daemon health never reached 200 (port $PORT)"
ok "daemon up on port $PORT (mode=$MODE)"
pass_stage

# ============================================================
# Stage 2 — scratch project repo (library + tests + verify)
# ============================================================
stage "stage 2: scratch project repo"
SCRATCH="$TMP/proj"
mkdir -p "$SCRATCH"
git -C "$SCRATCH" init -q -b main
git -C "$SCRATCH" config user.email "o@example.com"
git -C "$SCRATCH" config user.name "O Acceptance"

cat > "$SCRATCH/lib.sh" <<'SH'
#!/bin/sh
# tiny shell string library
shout() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
SH

cat > "$SCRATCH/tests.sh" <<'SH'
#!/bin/sh
# exercises the library and exits nonzero on any broken function
. ./lib.sh
[ "$(shout hi)" = "HI" ] || { echo "shout() broken"; exit 1; }
echo "tests: ok"
SH

# verify.sh runs the tests AND carries the [sim:regress]-compatible trap
# used by scripts/check.sh: a committed `boom` with no PROMPT.txt beside it
# fails — green in the worktree (sim leaves PROMPT.txt untracked), red on
# main after the merge, which is what makes the auto-revert drill fire.
cat > "$SCRATCH/verify.sh" <<'SH'
#!/bin/sh
if [ -f boom ] && [ ! -f PROMPT.txt ]; then echo "regression: boom without PROMPT.txt"; exit 1; fi
sh tests.sh
SH

echo "scratch acceptance project" > "$SCRATCH/README.md"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" commit -q -m "seed scratch project"
( cd "$SCRATCH" && sh verify.sh ) >/dev/null 2>&1 || die "seed verify.sh not green"
ok "repo seeded: lib.sh + tests.sh + verify.sh, verify green at HEAD"
pass_stage

# ============================================================
# Stage 3 — create the company wired to the scratch repo
# ============================================================
stage "stage 3: create company (repo + verify + protected + daily budget)"
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Acceptance Co\",\"issue_prefix\":\"ACC\",\"budget_monthly_cents\":1000000,\"budget_daily_cents\":2000,\"repo\":\"$SCRATCH\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"verify.sh,tests.sh\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; die "POST company expected 201, got $sc"; }
CID="$(jget "$body" 'd["id"]')"
[ -n "$CID" ] || die "company id missing"
python3 - "$body" "$SCRATCH" <<'PY' || die "company fields wrong"
import sys, json
d = json.loads(sys.argv[1])
assert d["repo"] == sys.argv[2], d.get("repo")
assert d["verify_cmd"] == "sh verify.sh", d.get("verify_cmd")
assert d["protected_paths"] == "verify.sh,tests.sh", d.get("protected_paths")
assert d["budget_daily_cents"] == 2000, d.get("budget_daily_cents")
PY
ok "Acceptance Co ($CID) wired to $SCRATCH"
pass_stage

# ============================================================
# Stage 4 — an agent ships a change; it verifies and merges
# ============================================================
stage "stage 4: agent ships a change -> verify -> merge (mode=$MODE)"
if [ "$MODE" = "real" ]; then
  ocurl -s -X POST "$BASE/api/companies/$CID/agents" \
    -H 'Content-Type: application/json' \
    -d '{"name":"Builder","role":"engineer","runtime":"claude-code","repo":"'"$SCRATCH"'"}' >/dev/null
  resp="$(ocurl -s -X POST "$BASE/api/companies/$CID/issues" \
    -H 'Content-Type: application/json' \
    -d '{"title":"Add a slugify function to lib.sh with a test in tests.sh","priority":"high"}')"
  IID_BUILD="$(jget "$resp" 'd["id"]')"
  CAP=900
else
  ocurl -s -X POST "$BASE/api/companies/$CID/agents" \
    -H 'Content-Type: application/json' \
    -d '{"name":"Builder","runtime":"sim","repo":"'"$SCRATCH"'"}' >/dev/null
  resp="$(ocurl -s -X POST "$BASE/api/companies/$CID/issues" \
    -H 'Content-Type: application/json' -d '{"title":"[sim:good] add file"}')"
  IID_BUILD="$(jget "$resp" 'd["id"]')"
  CAP=120
fi
[ -n "$IID_BUILD" ] || die "build issue id missing"
if wait_issue_status "$BASE" "$IID_BUILD" "Done" "$CAP"; then
  git -C "$SCRATCH" log --oneline main | grep "o/$IID_BUILD" >/dev/null \
    || { git -C "$SCRATCH" log --oneline main; die "no merge commit for o/$IID_BUILD on main"; }
  ( cd "$SCRATCH" && sh verify.sh ) >/dev/null 2>&1 || die "main not green after merge"
  ok "issue $IID_BUILD reached Done, merge commit on main, main green"
  pass_stage
else
  cat "$TMP/daemon.log" || true; die "build issue never reached Done"
fi

# ============================================================
# Stage 5 — regression drill: caught, reverted, fix filed, ranked first
# ============================================================
stage "stage 5: regression -> auto-revert -> fix issue ranked first"
# In real mode we need a deterministic sim agent to inject a known regression.
if [ "$MODE" = "real" ]; then
  ocurl -s -X POST "$BASE/api/companies/$CID/agents" \
    -H 'Content-Type: application/json' \
    -d '{"name":"Regressor","runtime":"sim","repo":"'"$SCRATCH"'"}' >/dev/null
fi
resp="$(ocurl -s -X POST "$BASE/api/companies/$CID/issues" \
  -H 'Content-Type: application/json' -d '{"title":"[sim:regress] introduce regression"}')"
IID_REG="$(jget "$resp" 'd["id"]')"
[ -n "$IID_REG" ] || die "regress issue id missing"
if wait_issue_status "$BASE" "$IID_REG" "Reverted" 150; then
  git -C "$SCRATCH" log --oneline main | grep -i "revert" >/dev/null \
    || { git -C "$SCRATCH" log --oneline main; die "no revert commit on main"; }
  ( cd "$SCRATCH" && sh verify.sh ) >/dev/null 2>&1 || die "main not green after revert"
  ok "issue $IID_REG Reverted, revert commit on main, main green again"
else
  cat "$TMP/daemon.log" || true; die "regress issue never reached Reverted"
fi

# the fix issue: exactly one OPEN, origin=auto, priority=high, fp revert:<ident>
IDENT="$(sqlite3 "$TMP/o.db" "SELECT identifier FROM issue WHERE id='$IID_REG'")"
[ -n "$IDENT" ] || die "could not read reverted issue identifier"
FP_REV="revert:$IDENT"
fix_ok=""
for _i in $(seq 1 20); do
  n="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CID' AND fingerprint='$FP_REV' AND origin='auto' AND priority='high' AND status NOT IN ('Done','Canceled','Failed','Reverted')")"
  if [ "${n:-0}" = "1" ]; then fix_ok="1"; break; fi
  sleep 1
done
[ -n "$fix_ok" ] || { cat "$TMP/daemon.log" || true; die "expected exactly 1 open $FP_REV origin=auto high issue, got ${n:-0}"; }
ok "fix issue filed: 1 open $FP_REV, origin=auto, priority=high"

# candidate ordering: the auto/high fix issue must outrank an OLDER, lower-
# priority operator issue. Insert a decoy with an EARLIER created_at so only
# the origin/priority ranking (not created_at) can put the fix issue first,
# assert, then delete the decoy (never dispatched).
sqlite3 "$TMP/o.db" "INSERT INTO issue (id, company_id, identifier, title, status, priority, sort_order, created_at, updated_at, origin, fingerprint) VALUES ('decoy_acc','$CID','ACC-DECOY','decoy older low-pri','Backlog','low',1,1,1,'operator','')"
TOP="$(sqlite3 "$TMP/o.db" "SELECT fingerprint FROM issue WHERE company_id='$CID' AND status NOT IN ('Done','Canceled','Failed','Reverted') ORDER BY CASE WHEN origin='auto' THEN 0 ELSE 1 END, CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, created_at ASC LIMIT 1")"
sqlite3 "$TMP/o.db" "DELETE FROM issue WHERE id='decoy_acc'"
[ "$TOP" = "$FP_REV" ] || die "fix issue did not rank first in candidate ordering (top fp='$TOP')"
ok "fix issue ranks FIRST in candidate ordering, ahead of an older low-pri issue"
pass_stage

# ============================================================
# Stage 6 — self-file DEDUP holds (no fork bomb)
# ============================================================
stage "stage 6: self-file dedup (re-trip the same fingerprint)"
# revert:<ident> fingerprints are per-ident distinct, so two reverts can't
# prove dedup. Prove it the honest way (as check.sh / tests/heldout do):
# re-trip the SAME no-signal fingerprint on a dedicated company while its
# first diagnostic is still open -> the second auto-file must be deduped.
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Dedup Co","issue_prefix":"DUP","budget_daily_cents":1000}')"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; die "POST dedup company expected 201, got $sc"; }
CIDD="$(jget "$body" 'd["id"]')"
FP_NS="no-signal:$CIDD"
DAY_MINUS1="(strftime('%s','now')*1000/86400000)-1"
# no_signal_days=1 so ONE stale-day rollover crosses the default threshold (2)
# and files the diagnostic; a second re-arm crosses it again -> dup.
sqlite3 "$TMP/o.db" "UPDATE company SET spent_today_cents=900, greens_today=0, no_signal_days=1, status='active', pause_reason='', budget_day=$DAY_MINUS1 WHERE id='$CIDD'"
created_ok=""
for _i in $(seq 1 25); do
  n="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CIDD' AND fingerprint='$FP_NS' AND origin='auto'")"
  ncr="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM activity WHERE verb='selffile.created' AND target='$FP_NS'")"
  if [ "${n:-0}" = "1" ] && [ "${ncr:-0}" = "1" ]; then created_ok="1"; break; fi
  sleep 1
done
[ -n "$created_ok" ] || { cat "$TMP/daemon.log" || true; die "first trip did not file exactly one $FP_NS issue (n=${n:-?} created=${ncr:-?})"; }
ok "first trip filed exactly one $FP_NS issue (selffile.created)"

sqlite3 "$TMP/o.db" "UPDATE company SET spent_today_cents=900, greens_today=0, budget_day=$DAY_MINUS1 WHERE id='$CIDD'"
duped_ok=""
for _i in $(seq 1 25); do
  nd="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM activity WHERE verb='selffile.duped' AND target='$FP_NS'")"
  if [ "${nd:-0}" -ge 1 ]; then duped_ok="1"; break; fi
  sleep 1
done
[ -n "$duped_ok" ] || { cat "$TMP/daemon.log" || true; die "selffile.duped never logged for $FP_NS after re-trip"; }
nopen="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CIDD' AND fingerprint='$FP_NS' AND status NOT IN ('Done','Canceled','Failed','Reverted')")"
[ "$nopen" = "1" ] || die "expected exactly 1 open $FP_NS issue, got $nopen"
ok "re-trip deduped: 1 open $FP_NS issue + selffile.duped logged"
pass_stage

# ============================================================
# Stage 7 — budget circuit breaker: pause on cap, reset on rollover
# ============================================================
stage "stage 7: daily budget breaker -> pause -> rollover reset"
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Budget Co","issue_prefix":"BUD","budget_daily_cents":2000}')"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; die "POST budget company expected 201, got $sc"; }
CIDB="$(jget "$body" 'd["id"]')"
ocurl -s -X POST "$BASE/api/companies/$CIDB/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Burner","runtime":"sim"}' >/dev/null
# Seed spent_today PAST the daily cap, stamping budget_day=today so the tick's
# rollover won't wipe the seed. The next run's cost trips enforce_budget.
TODAY="(strftime('%s','now')*1000/86400000)"
sqlite3 "$TMP/o.db" "UPDATE company SET spent_today_cents=2100, greens_today=0, no_signal_days=0, budget_day=$TODAY WHERE id='$CIDB'"
resp="$(ocurl -s -X POST "$BASE/api/companies/$CIDB/issues" \
  -H 'Content-Type: application/json' -d '{"title":"burn"}')"
IID_BURN="$(jget "$resp" 'd["id"]')"
paused_ok=""
for _i in $(seq 1 60); do
  b="$(ocurl -s "$BASE/api/companies/$CIDB")"
  st="$(jget "$b" 'd["status"]' 2>/dev/null || true)"
  pr="$(jget "$b" 'd["pause_reason"]' 2>/dev/null || true)"
  if [ "$st" = "paused" ] && [ "$pr" = "budget-daily" ]; then paused_ok="1"; break; fi
  sleep 1
done
[ -n "$paused_ok" ] || { cat "$TMP/daemon.log" || true; die "budget company never paused budget-daily (status=${st:-?} reason=${pr:-?})"; }
ok "company paused on daily cap (pause_reason=budget-daily)"

# No open issue may survive the rollover (else it re-charges + re-pauses).
sqlite3 "$TMP/o.db" "UPDATE issue SET status='Canceled' WHERE id='$IID_BURN' AND status NOT IN ('Done','Canceled','Failed','Reverted')"
# Rewind the ledger day; the next tick's rollover resets spend + un-pauses.
sqlite3 "$TMP/o.db" "UPDATE company SET budget_day = budget_day - 1 WHERE id='$CIDB'"
rolled_ok=""
for _i in $(seq 1 25); do
  b="$(ocurl -s "$BASE/api/companies/$CIDB")"
  st="$(jget "$b" 'd["status"]' 2>/dev/null || true)"
  sp="$(jget "$b" 'd["spent_today_cents"]' 2>/dev/null || true)"
  if [ "$st" = "active" ] && [ "$sp" = "0" ]; then rolled_ok="1"; break; fi
  sleep 1
done
[ -n "$rolled_ok" ] || { cat "$TMP/daemon.log" || true; die "rollover never reset budget company (status=${st:-?} spent=${sp:-?})"; }
sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM activity WHERE company_id='$CIDB' AND verb='budget.reset'" | grep -q '^[1-9]' \
  || die "budget.reset not logged"
ok "rollover reset spend + un-paused, budget.reset logged"
pass_stage

# ============================================================
# Stage 8 — daily reflection pass files an improvement issue
# ============================================================
stage "stage 8: reflection pass (O_REFLECT=1, stub claude)"
TMP2="$(mktemp -d)"
PORT2=$((5950 + RANDOM % 300))
BASE2="http://127.0.0.1:${PORT2}"
# The stub stands in for `claude -p`: it scrapes the /issues endpoint out of
# the piped reflection prompt, POSTs one reflect-origin issue, and prints a
# single {type:result} event reporting $0.05 — same shape check.sh uses.
cat > "$TMP2/claude-stub" <<'STUB'
#!/usr/bin/env bash
prompt="$(cat)"
url="$(printf '%s' "$prompt" | grep -oE 'http://127[^ ]*/issues' | head -n1)"
if [ -n "$url" ]; then
  curl -s --max-time 10 -X POST "$url" -H 'Content-Type: application/json' \
    -d '{"title":"stub reflection improvement","body":"filed by the reflect stub","priority":"medium","origin":"reflect"}' >/dev/null 2>&1 || true
fi
printf '%s\n' '{"type":"result","total_cost_usd":0.05,"session_id":"stub"}'
exit 0
STUB
chmod +x "$TMP2/claude-stub"
HOME="$TMP2" O_DB="$TMP2/o.db" O_PORT="$PORT2" O_NO_OPEN=1 O_REFLECT=1 \
  O_CLAUDE_BIN="$TMP2/claude-stub" ./bin/swarmd >"$TMP2/daemon.log" 2>&1 &
DAEMON2_PID=$!
wait_health "$BASE2" "$DAEMON2_PID" "$TMP2/daemon" || die "reflect daemon health never reached 200 (port $PORT2)"

SCRATCHR="$TMP2/projr"
mkdir -p "$SCRATCHR"
git -C "$SCRATCHR" init -q -b main
git -C "$SCRATCHR" config user.email "o@example.com"
git -C "$SCRATCHR" config user.name "O Acceptance"
cp "$SCRATCH/verify.sh" "$SCRATCHR/verify.sh"
echo "reflect project" > "$SCRATCHR/README.md"
git -C "$SCRATCHR" add -A
git -C "$SCRATCHR" commit -q -m "seed reflect project"

# Company WITH repo + verify_cmd but deliberately NO agent, so the reflect-
# filed Backlog issue is never consumed and the stage stays deterministic.
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE2/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Reflect Co\",\"issue_prefix\":\"RFL\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCHR\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; die "POST reflect company expected 201, got $sc"; }
CID_R="$(jget "$body" 'd["id"]')"
reflect_ok=""
for _i in $(seq 1 40); do
  nsp="$(sqlite3 "$TMP2/o.db" "SELECT COUNT(*) FROM activity WHERE company_id='$CID_R' AND verb='reflect.spawn'")"
  nref="$(sqlite3 "$TMP2/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CID_R' AND origin='reflect'")"
  if [ "${nsp:-0}" -ge 1 ] && [ "${nref:-0}" = "1" ]; then reflect_ok="1"; break; fi
  sleep 1
done
[ -n "$reflect_ok" ] || { cat "$TMP2/daemon.log" || true; die "reflection did not spawn + file one issue (spawn=${nsp:-?} reflect_issues=${nref:-?})"; }
ok "reflect.spawn logged and exactly one origin=reflect issue filed"
pass_stage

# ============================================================
print_matrix
echo
echo "ACCEPTANCE GREEN (mode=$MODE)"
