#!/usr/bin/env bash
# ============================================================
# O v4 — check.sh  (hermetic test suite, v0)
# ============================================================
#
# Boots swarmd on a throwaway DB + random port, drives the REST
# API through a full create -> dispatch -> Done pipeline against
# the deterministic `sim` runtime, and asserts the activity log.
#
# Never touches ~/.o live state and never binds :4100. A trap
# tears the daemon down and removes the temp DB on any exit, so a
# failing assert can never leak a running daemon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DAEMON_PID=""
TMP=""

cleanup() {
  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "$TMP" ]; then
    rm -rf "$TMP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# jget <json> <python-expr-on-d>  — print a value from a JSON blob.
jget() {
  printf '%s' "$1" | python3 -c "import sys,json;d=json.load(sys.stdin);print($2)"
}

# ---- stage a: build -----------------------------------------
if make >/dev/null 2>&1; then
  pass "build (make)"
else
  make || true
  fail "build (make)"
fi

# ---- stage b: boot daemon on temp DB + random port ----------
TMP="$(mktemp -d)"
PORT=$((4200 + RANDOM % 400))
BASE="http://127.0.0.1:${PORT}"

# HOME is redirected into $TMP so the daemon's per-issue git worktrees
# (created under $HOME/.o/workspaces by the verify gate below) land in the
# throwaway dir and never touch the operator's live ~/.o state.
HOME="$TMP" O_DB="$TMP/o.db" O_PORT="$PORT" O_NO_OPEN=1 ./bin/swarmd >"$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!

up=""
for _i in $(seq 1 30); do
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    cat "$TMP/daemon.log" || true
    fail "daemon exited during boot"
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then up="1"; break; fi
  sleep 0.5
done
[ -n "$up" ] || { cat "$TMP/daemon.log" || true; fail "daemon health never reached 200 (port $PORT)"; }
pass "daemon up on port $PORT (health 200)"

# ---- stage c: API smoke -------------------------------------
# create company
resp="$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Smoke Co","issue_prefix":"TST","budget_monthly_cents":100000}')"
sc="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST /api/companies expected 201, got $sc"; }
CID="$(jget "$body" 'd["id"]')"
[ -n "$CID" ] || fail "company id missing in create response"
pass "POST /api/companies -> 201 (id $CID)"

# create agent (sim runtime)
resp="$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies/$CID/agents" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Simmy","runtime":"sim"}')"
sc="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST agents expected 201, got $sc"; }
AID="$(jget "$body" 'd["id"]')"
[ -n "$AID" ] || fail "agent id missing in create response"
pass "POST /api/companies/:id/agents -> 201 (id $AID)"

# create issue
resp="$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies/$CID/issues" \
  -H 'Content-Type: application/json' \
  -d '{"title":"smoke"}')"
sc="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST issues expected 201, got $sc"; }
IID="$(jget "$body" 'd["id"]')"
[ -n "$IID" ] || fail "issue id missing in create response"
pass "POST /api/companies/:id/issues -> 201 (id $IID)"

# ---- read each back and assert fields -----------------------
body="$(curl -s "$BASE/api/companies/$CID")"
python3 - "$body" <<'PY' || fail "GET company field assertions failed"
import sys, json
d = json.loads(sys.argv[1])
assert d["name"] == "Smoke Co", d.get("name")
assert d["issue_prefix"] == "TST", d.get("issue_prefix")
assert d["budget_monthly_cents"] == 100000, d.get("budget_monthly_cents")
PY
pass "GET /api/companies/:id fields (name, issue_prefix=TST, budget)"

body="$(curl -s "$BASE/api/companies/$CID/agents")"
python3 - "$body" "$AID" <<'PY' || fail "GET agents field assertions failed"
import sys, json
rows = json.loads(sys.argv[1]); aid = sys.argv[2]
a = next(r for r in rows if r["id"] == aid)
assert a["name"] == "Simmy", a.get("name")
assert a["runtime"] == "sim", a.get("runtime")
PY
pass "GET /api/companies/:id/agents fields (name, runtime=sim)"

body="$(curl -s "$BASE/api/issues/$IID")"
python3 - "$body" <<'PY' || fail "GET issue field assertions failed"
import sys, json
d = json.loads(sys.argv[1])
assert d["title"] == "smoke", d.get("title")
assert d["status"] in ("Backlog", "Todo", "In Progress", "Done"), d.get("status")
PY
pass "GET /api/issues/:id fields (title=smoke)"

# ---- stage d: pipeline drives issue to Done -----------------
# sim runs ~1s; even-sort_order issues crash attempt 1 by design and
# retry after ~2s backoff on 5s ticks, so allow up to 60s.
done_ok=""
for _i in $(seq 1 60); do
  st="$(jget "$(curl -s "$BASE/api/issues/$IID")" 'd["status"]' 2>/dev/null || true)"
  if [ "$st" = "Done" ]; then done_ok="1"; break; fi
  sleep 1
done
[ -n "$done_ok" ] || { cat "$TMP/daemon.log" || true; fail "issue never reached Done (last status: ${st:-none})"; }
pass "pipeline: issue $IID reached Done"

# ---- stage e: activity log has run.succeeded ----------------
body="$(curl -s "$BASE/api/activity")"
python3 - "$body" <<'PY' || fail "activity log missing run.succeeded"
import sys, json
rows = json.loads(sys.argv[1])
verbs = [r.get("verb") for r in rows]
assert "run.succeeded" in verbs, verbs
PY
pass "GET /api/activity contains run.succeeded"

# ---- stage f: daily budget ledger — pause + rollover ---------
# A company with budget_daily_cents=100 and a sim agent (each run
# costs 300) must hard-stop on the DAILY cap after its first run,
# with pause_reason="budget-daily". Rewinding budget_day by one day
# then makes the next tick's rollover reset spent_today and un-pause.
resp="$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Daily Co","issue_prefix":"DAY","budget_daily_cents":100}')"
sc="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST daily-budget company expected 201, got $sc"; }
CID2="$(jget "$body" 'd["id"]')"
python3 - "$body" <<'PY' || fail "created company missing budget_daily_cents field"
import sys, json
d = json.loads(sys.argv[1])
assert d["budget_daily_cents"] == 100, d.get("budget_daily_cents")
assert d["status"] == "active", d.get("status")
PY
pass "POST /api/companies daily budget -> 201 (id $CID2, budget_daily_cents=100)"

curl -s -X POST "$BASE/api/companies/$CID2/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Dailysim","runtime":"sim"}' >/dev/null
curl -s -X POST "$BASE/api/companies/$CID2/issues" \
  -H 'Content-Type: application/json' -d '{"title":"burn"}' >/dev/null

# Wait for the daily cap to hard-stop the company.
paused_ok=""
for _i in $(seq 1 60); do
  body="$(curl -s "$BASE/api/companies/$CID2")"
  st="$(jget "$body" 'd["status"]' 2>/dev/null || true)"
  if [ "$st" = "paused" ]; then paused_ok="1"; break; fi
  sleep 1
done
[ -n "$paused_ok" ] || { cat "$TMP/daemon.log" || true; fail "daily-budget company never paused (last status: ${st:-none})"; }
body="$(curl -s "$BASE/api/companies/$CID2")"
python3 - "$body" <<'PY' || fail "expected pause_reason=budget-daily"
import sys, json
d = json.loads(sys.argv[1])
assert d["status"] == "paused", d.get("status")
assert d["pause_reason"] == "budget-daily", d.get("pause_reason")
assert d["spent_today_cents"] >= 100, d.get("spent_today_cents")
PY
pass "daily cap: company $CID2 paused with pause_reason=budget-daily"

# Cancel the open issue so the rolled-over company has no candidate to
# re-dispatch (which would re-charge 300 and re-pause) — we are
# asserting the rollover reset, not the re-dispatch.
IID2="$(jget "$(curl -s "$BASE/api/companies/$CID2/issues")" 'd[0]["id"]')"
curl -s -X POST "$BASE/api/issues/$IID2" \
  -H 'Content-Type: application/json' -d '{"status":"Canceled"}' >/dev/null

# Rewind the ledger day; the next tick's rollover must reset + un-pause.
sqlite3 "$TMP/o.db" "UPDATE company SET budget_day = budget_day - 1 WHERE id='$CID2'"

rolled_ok=""
for _i in $(seq 1 20); do
  body="$(curl -s "$BASE/api/companies/$CID2")"
  st="$(jget "$body" 'd["status"]' 2>/dev/null || true)"
  sp="$(jget "$body" 'd["spent_today_cents"]' 2>/dev/null || true)"
  if [ "$st" = "active" ] && [ "$sp" = "0" ]; then rolled_ok="1"; break; fi
  sleep 1
done
[ -n "$rolled_ok" ] || { cat "$TMP/daemon.log" || true; fail "rollover never reset company $CID2 (status=${st:-none} spent_today=${sp:-none})"; }
pass "rollover: company $CID2 active again, spent_today_cents=0"

body="$(curl -s "$BASE/api/activity")"
python3 - "$body" <<'PY' || fail "activity log missing budget.reset"
import sys, json
rows = json.loads(sys.argv[1])
verbs = [r.get("verb") for r in rows]
assert "budget.reset" in verbs, verbs
PY
pass "GET /api/activity contains budget.reset"

# ---- stage g: VERIFY GATE — grounded verifier -----------------
# A scratch project repo whose verify.sh (a) fails when BREAK_VERIFY is
# present and (b) fails when `boom` exists without PROMPT.txt (the phase-3
# regression trap — green in the worktree where PROMPT.txt sits untracked).
# A company points at it (repo + verify_cmd + protected_paths) with a sim
# agent, and the repo-aware sim drives every verdict branch off the issue
# title marker.
SCRATCH="$TMP/proj"
mkdir -p "$SCRATCH"
git -C "$SCRATCH" init -q -b main
git -C "$SCRATCH" config user.email "o@example.com"
git -C "$SCRATCH" config user.name "O Test"
cat > "$SCRATCH/verify.sh" <<'SH'
#!/bin/sh
if [ -f BREAK_VERIFY ]; then echo "BREAK_VERIFY present"; exit 1; fi
if [ -f boom ] && [ ! -f PROMPT.txt ]; then echo "regression: boom without PROMPT.txt"; exit 1; fi
exit 0
SH
echo "scratch verify-gate project" > "$SCRATCH/README.md"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" commit -q -m "seed verify project"

# company wired to the scratch repo + verify command + a protected prefix
resp="$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Verify Co\",\"issue_prefix\":\"VER\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCH\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST verify-gate company expected 201, got $sc"; }
CID3="$(jget "$body" 'd["id"]')"
python3 - "$body" "$SCRATCH" <<'PY' || fail "verify-gate company fields wrong"
import sys, json
d = json.loads(sys.argv[1])
assert d["repo"] == sys.argv[2], d.get("repo")
assert d["verify_cmd"] == "sh verify.sh", d.get("verify_cmd")
assert d["protected_paths"] == "protected/", d.get("protected_paths")
PY
pass "POST /api/companies verify-gate -> 201 (id $CID3, repo wired)"

curl -s -X POST "$BASE/api/companies/$CID3/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Versim","runtime":"sim"}' >/dev/null
pass "verify-gate sim agent hired"

# fire all four marker issues up front so they process concurrently
mk_issue() {
  local resp
  resp="$(curl -s -X POST "$BASE/api/companies/$CID3/issues" \
    -H 'Content-Type: application/json' -d "{\"title\":\"$1\"}")"
  jget "$resp" 'd["id"]'
}
IID_GOOD="$(mk_issue '[sim:good] add file')"
IID_NC="$(mk_issue '[sim:no-commit] nothing')"
IID_PROT="$(mk_issue '[sim:protected] sneaky')"
IID_BAD="$(mk_issue '[sim:bad-verify] break')"
for x in "$IID_GOOD" "$IID_NC" "$IID_PROT" "$IID_BAD"; do
  [ -n "$x" ] || fail "verify-gate issue id missing"
done
pass "verify-gate issues created (good/no-commit/protected/bad-verify)"

# wait_status <iid> <want> <max-seconds>
wait_status() {
  local st=""
  for _i in $(seq 1 "$3"); do
    st="$(jget "$(curl -s "$BASE/api/issues/$1")" 'd["status"]' 2>/dev/null || true)"
    if [ "$st" = "$2" ]; then return 0; fi
    sleep 1
  done
  echo "  last status of $1: ${st:-none}"
  return 1
}

# last run's verify_state for an issue, read straight from the control plane
last_verify_state() {
  sqlite3 "$TMP/o.db" "SELECT verify_state FROM run WHERE issue_id='$1' ORDER BY started_at DESC LIMIT 1"
}

# [sim:good] — a real commit that passes verify.sh -> Done
if wait_status "$IID_GOOD" "Done" 90; then
  pass "verify-gate: [sim:good] reached Done"
else
  cat "$TMP/daemon.log" || true; fail "[sim:good] never reached Done"
fi

# [sim:no-commit] — 3 attempts, each red_no_commit, then Failed
if wait_status "$IID_NC" "Failed" 120; then
  vs="$(last_verify_state "$IID_NC")"
  [ "$vs" = "red_no_commit" ] || fail "[sim:no-commit] last verify_state expected red_no_commit, got '$vs'"
  pass "verify-gate: [sim:no-commit] Failed with verify_state=red_no_commit"
else
  cat "$TMP/daemon.log" || true; fail "[sim:no-commit] never reached Failed"
fi

# [sim:protected] — commit under protected/ -> red_protected, Failed
if wait_status "$IID_PROT" "Failed" 120; then
  vs="$(last_verify_state "$IID_PROT")"
  [ "$vs" = "red_protected" ] || fail "[sim:protected] last verify_state expected red_protected, got '$vs'"
  pass "verify-gate: [sim:protected] Failed with verify_state=red_protected"
else
  cat "$TMP/daemon.log" || true; fail "[sim:protected] never reached Failed"
fi

# [sim:bad-verify] — commit BREAK_VERIFY -> verify.sh fails -> red_tests, Failed
if wait_status "$IID_BAD" "Failed" 120; then
  vs="$(last_verify_state "$IID_BAD")"
  [ "$vs" = "red_tests" ] || fail "[sim:bad-verify] last verify_state expected red_tests, got '$vs'"
  pass "verify-gate: [sim:bad-verify] Failed with verify_state=red_tests"
else
  cat "$TMP/daemon.log" || true; fail "[sim:bad-verify] never reached Failed"
fi

# activity records both a pass and a fail
body="$(curl -s "$BASE/api/activity")"
python3 - "$body" <<'PY' || fail "verify-gate activity missing verify.pass / verify.fail"
import sys, json
verbs = [r.get("verb") for r in json.loads(sys.argv[1])]
assert "verify.pass" in verbs, verbs
assert "verify.fail" in verbs, verbs
PY
pass "GET /api/activity contains verify.pass and verify.fail"

echo
echo "ALL GREEN"
