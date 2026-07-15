#!/usr/bin/env bash
# ============================================================
# O — tests/heldout/core.sh  (the FROZEN invariant suite)
# ============================================================
#
# The loop rewrites its own code. This file is the contract it may
# NOT break: a lean set of INVARIANTS that must hold no matter what a
# self-modifying agent does to the rest of the tree. It is listed in
# the "O Core" company's protected_paths, so an agent cannot edit the
# very checks that gate its merges.
#
# Conventions mirror scripts/check.sh exactly: set -euo pipefail, a
# throwaway daemon on a temp DB + random port, an ocurl helper with a
# hard timeout + one retry, and a trap that tears the daemon down and
# removes the temp dir on any exit. Kept deliberately small (~6
# assertions) — the full pipeline lives in check.sh; this is the frozen
# core that proves the safety machinery is still alive.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# curl with a hard wall-clock cap + ONE retry on exit 52 (swarmrt's http
# server occasionally idle-closes a keep-alive socket mid-response).
ocurl() {
  local out rc
  out="$(curl --max-time 10 "$@")"; rc=$?
  if [ "$rc" = "52" ]; then
    out="$(curl --max-time 10 "$@")"; rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

jget() {
  printf '%s' "$1" | python3 -c "import sys,json;d=json.load(sys.stdin);print($2)"
}

# ---- invariant 1: daemon boots, /api/health 200 --------------
# O_NO_SIGNAL_DAYS=1 makes the no-signal breaker fire in a single
# rollover, which the dedup invariant (6) below re-trips on purpose.
[ -x "./bin/swarmd" ] || fail "bin/swarmd missing (run make first)"
TMP="$(mktemp -d)"
PORT=$((5300 + RANDOM % 300))
BASE="http://127.0.0.1:${PORT}"
HOME="$TMP" O_DB="$TMP/o.db" O_PORT="$PORT" O_NO_OPEN=1 O_NO_SIGNAL_DAYS=1 \
  ./bin/swarmd >"$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!

up=""
for _i in $(seq 1 30); do
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then cat "$TMP/daemon.log" || true; fail "daemon exited during boot"; fi
  code="$(ocurl -s -o /dev/null -w '%{http_code}' "$BASE/api/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then up="1"; break; fi
  sleep 0.5
done
[ -n "$up" ] || { cat "$TMP/daemon.log" || true; fail "daemon health never reached 200 (port $PORT)"; }
pass "invariant 1: daemon boots, /api/health 200 (port $PORT)"

# ---- invariant 2: company/agent/issue CRUD -------------------
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Core Co","issue_prefix":"COR","budget_monthly_cents":100000}')"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST /api/companies expected 201, got $sc"; }
CID="$(jget "$body" 'd["id"]')"
[ -n "$CID" ] || fail "company id missing"

resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies/$CID/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Simmy","runtime":"sim"}')"
sc="$(printf '%s' "$resp" | tail -n1)"
[ "$sc" = "201" ] || fail "POST agents expected 201, got $sc"

resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies/$CID/issues" \
  -H 'Content-Type: application/json' -d '{"title":"smoke"}')"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || fail "POST issues expected 201, got $sc"
IID="$(jget "$body" 'd["id"]')"
[ -n "$IID" ] || fail "issue id missing"

# read each back
python3 - "$(ocurl -s "$BASE/api/companies/$CID")" <<'PY' || fail "company read-back wrong"
import sys, json
d = json.loads(sys.argv[1])
assert d["name"] == "Core Co" and d["issue_prefix"] == "COR", d
PY
python3 - "$(ocurl -s "$BASE/api/issues/$IID")" <<'PY' || fail "issue read-back wrong"
import sys, json
d = json.loads(sys.argv[1])
assert d["title"] == "smoke", d
PY
pass "invariant 2: company/agent/issue CRUD round-trips"

# ---- set up the verify-gate company (repo + verify + protected) ----
# A scratch repo whose verify.sh fails on a BREAK_VERIFY file or a boom
# without PROMPT.txt — the exact convention scripts/check.sh uses.
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
echo "heldout verify project" > "$SCRATCH/README.md"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" commit -q -m "seed verify project"

resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Verify Co\",\"issue_prefix\":\"VER\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCH\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST verify company expected 201, got $sc"; }
CIDV="$(jget "$body" 'd["id"]')"
ocurl -s -X POST "$BASE/api/companies/$CIDV/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Versim","runtime":"sim"}' >/dev/null

mk_issue() {
  jget "$(ocurl -s -X POST "$BASE/api/companies/$CIDV/issues" \
    -H 'Content-Type: application/json' -d "{\"title\":\"$1\"}")" 'd["id"]'
}
IID_NC="$(mk_issue '[sim:no-commit] nothing')"
IID_PROT="$(mk_issue '[sim:protected] sneaky')"
[ -n "$IID_NC" ] && [ -n "$IID_PROT" ] || fail "verify issue ids missing"

# ---- set up the dedup company + arm the first no-signal trip --------
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Dedup Co","issue_prefix":"DUP","budget_daily_cents":1000}')"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST dedup company expected 201, got $sc"; }
CIDD="$(jget "$body" 'd["id"]')"
[ -n "$CIDD" ] || fail "dedup company id missing"
FP="no-signal:$CIDD"
DAY_MINUS1="(strftime('%s','now')*1000/86400000)-1"
# 900/1000 spent, 0 greens, stale day -> next rollover trips the breaker
# (threshold 1) and auto-files ONE origin=auto issue fingerprinted $FP.
sqlite3 "$TMP/o.db" "UPDATE company SET spent_today_cents=900, greens_today=0, no_signal_days=0, status='active', pause_reason='', budget_day=$DAY_MINUS1 WHERE id='$CIDD'"

# ---- helpers for the concurrent polls ------------------------
wait_status() {
  local st=""
  for _i in $(seq 1 "$3"); do
    st="$(jget "$(ocurl -s "$BASE/api/issues/$1")" 'd["status"]' 2>/dev/null || true)"
    if [ "$st" = "$2" ]; then return 0; fi
    sleep 1
  done
  echo "  last status of $1: ${st:-none}"
  return 1
}
last_verify_state() {
  sqlite3 "$TMP/o.db" "SELECT verify_state FROM run WHERE issue_id='$1' ORDER BY started_at DESC LIMIT 1"
}

# ---- invariant 3: a sim issue reaches Done -------------------
if wait_status "$IID" "Done" 90; then
  pass "invariant 3: sim issue reached Done"
else
  cat "$TMP/daemon.log" || true; fail "sim issue never reached Done"
fi

# ---- invariant 4: grounded verifier — red_no_commit ----------
if wait_status "$IID_NC" "Failed" 120; then
  vs="$(last_verify_state "$IID_NC")"
  [ "$vs" = "red_no_commit" ] || fail "[sim:no-commit] verify_state expected red_no_commit, got '$vs'"
  pass "invariant 4: [sim:no-commit] Failed with verify_state=red_no_commit"
else
  cat "$TMP/daemon.log" || true; fail "[sim:no-commit] never reached Failed"
fi

# ---- invariant 5: protected-paths teeth — red_protected ------
if wait_status "$IID_PROT" "Failed" 120; then
  vs="$(last_verify_state "$IID_PROT")"
  [ "$vs" = "red_protected" ] || fail "[sim:protected] verify_state expected red_protected, got '$vs'"
  pass "invariant 5: [sim:protected] Failed with verify_state=red_protected"
else
  cat "$TMP/daemon.log" || true; fail "[sim:protected] never reached Failed"
fi

# ---- invariant 6: self-file DEDUP ----------------------------
# The first no-signal trip files exactly one origin=auto issue with
# fingerprint $FP (selffile.created). Re-arming the SAME company trips the
# breaker a second time while that issue is still open — the auto-file must
# be deduped: NO second issue, and a selffile.duped activity entry. This is
# the regression guard against a self-modifying agent re-opening the
# fingerprint fork-bomb hole.
created_ok=""
for _i in $(seq 1 25); do
  n="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CIDD' AND fingerprint='$FP' AND origin='auto'")"
  ncr="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM activity WHERE verb='selffile.created' AND target='$FP'")"
  if [ "${n:-0}" = "1" ] && [ "${ncr:-0}" = "1" ]; then created_ok="1"; break; fi
  sleep 1
done
[ -n "$created_ok" ] || { cat "$TMP/daemon.log" || true; fail "dedup: first no-signal trip did not file exactly one $FP issue (n=${n:-?} created=${ncr:-?})"; }

# re-arm: spend high again with zero greens on a stale day -> second trip
sqlite3 "$TMP/o.db" "UPDATE company SET spent_today_cents=900, greens_today=0, budget_day=$DAY_MINUS1 WHERE id='$CIDD'"
duped_ok=""
for _i in $(seq 1 25); do
  nd="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM activity WHERE verb='selffile.duped' AND target='$FP'")"
  if [ "${nd:-0}" -ge 1 ]; then duped_ok="1"; break; fi
  sleep 1
done
[ -n "$duped_ok" ] || { cat "$TMP/daemon.log" || true; fail "dedup: selffile.duped never logged for $FP after re-trip"; }

# still exactly ONE open issue carrying the fingerprint (no fork bomb)
nopen="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CIDD' AND fingerprint='$FP' AND status NOT IN ('Done','Canceled','Failed','Reverted')")"
[ "$nopen" = "1" ] || fail "dedup: expected exactly 1 OPEN $FP issue, got $nopen"
pass "invariant 6: self-file dedup — re-trip yields 1 open $FP issue + selffile.duped"

echo
echo "HELDOUT GREEN"
