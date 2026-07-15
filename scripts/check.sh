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

# [sim:good] — a real commit that passes verify.sh -> auto-merged to main -> Done
if wait_status "$IID_GOOD" "Done" 90; then
  pass "verify-gate: [sim:good] reached Done"
else
  cat "$TMP/daemon.log" || true; fail "[sim:good] never reached Done"
fi

# phase3: green auto-merged into main (a --no-ff merge commit naming the branch),
# and the worktree + branch were cleaned up.
# NB: plain `grep` (not `grep -q`) reads the stream to EOF, so `git log` never
# takes a SIGPIPE that `set -o pipefail` would turn into a false failure.
git -C "$SCRATCH" log --oneline main | grep "o/$IID_GOOD" >/dev/null \
  || { git -C "$SCRATCH" log --oneline main; fail "[sim:good] no merge commit for o/$IID_GOOD on main"; }
[ ! -d "$TMP/.o/workspaces/$IID_GOOD" ] || fail "[sim:good] worktree dir not removed"
[ -z "$(git -C "$SCRATCH" branch --list "o/$IID_GOOD")" ] || fail "[sim:good] branch o/$IID_GOOD not deleted"
pass "verify-gate: [sim:good] merged to main (merge commit), worktree + branch cleaned up"

# the merged run carries its merge_sha, and GET /api/runs/:id/result serves the
# archived artifacts even though the worktree is gone.
RID_GOOD="$(sqlite3 "$TMP/o.db" "SELECT id FROM run WHERE issue_id='$IID_GOOD' ORDER BY started_at DESC LIMIT 1")"
MSHA="$(sqlite3 "$TMP/o.db" "SELECT merge_sha FROM run WHERE id='$RID_GOOD'")"
[ -n "$MSHA" ] || fail "[sim:good] run has empty merge_sha"
rr="$(curl -s "$BASE/api/runs/$RID_GOOD/result")"
python3 - "$rr" "$MSHA" <<'PY' || fail "run result missing merge_sha / archived stream"
import sys, json
d = json.loads(sys.argv[1])
assert d["merge_sha"] == sys.argv[2], (d.get("merge_sha"), sys.argv[2])
PY
pass "verify-gate: run result exposes merge_sha ($MSHA) from archive"

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

# activity records a pass, a fail, and a completed merge
body="$(curl -s "$BASE/api/activity")"
python3 - "$body" <<'PY' || fail "verify-gate activity missing verify.pass / verify.fail / merge.done"
import sys, json
verbs = [r.get("verb") for r in json.loads(sys.argv[1])]
assert "verify.pass" in verbs, verbs
assert "verify.fail" in verbs, verbs
assert "merge.done" in verbs, verbs
PY
pass "GET /api/activity contains verify.pass, verify.fail and merge.done"

# ---- stage h: AUTO-REVERT on regression -----------------------
# A [sim:regress] issue commits `boom` (green in the worktree because PROMPT.txt
# sits untracked beside it) but regresses main after merge (boom without
# PROMPT.txt fails verify.sh). The merger must revert the merge on main and mark
# the issue Reverted, keeping the branch for forensics. A fresh repo isolates it.
SCRATCH2="$TMP/proj2"
mkdir -p "$SCRATCH2"
git -C "$SCRATCH2" init -q -b main
git -C "$SCRATCH2" config user.email "o@example.com"
git -C "$SCRATCH2" config user.name "O Test"
cp "$SCRATCH/verify.sh" "$SCRATCH2/verify.sh"
echo "regress project" > "$SCRATCH2/README.md"
git -C "$SCRATCH2" add -A
git -C "$SCRATCH2" commit -q -m "seed regress project"

resp="$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Regress Co\",\"issue_prefix\":\"REG\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCH2\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST regress company expected 201, got $sc"; }
CID4="$(jget "$body" 'd["id"]')"
curl -s -X POST "$BASE/api/companies/$CID4/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Regsim","runtime":"sim"}' >/dev/null
curl -s -X POST "$BASE/api/companies/$CID4/issues" \
  -H 'Content-Type: application/json' -d '{"title":"[sim:regress] boom"}' >/dev/null
IID_REG="$(jget "$(curl -s "$BASE/api/companies/$CID4/issues")" 'd[0]["id"]')"
[ -n "$IID_REG" ] || fail "regress issue id missing"

if wait_status "$IID_REG" "Reverted" 120; then
  git -C "$SCRATCH2" log --oneline main | grep -i "revert" >/dev/null \
    || { git -C "$SCRATCH2" log --oneline main; fail "regress: no Revert commit on main"; }
  ( cd "$SCRATCH2" && sh verify.sh ) >/dev/null 2>&1 \
    || fail "regress: verify.sh not green on main after revert"
  [ -n "$(git -C "$SCRATCH2" branch --list "o/$IID_REG")" ] \
    || fail "regress: branch o/$IID_REG should be kept for forensics"
  vs="$(last_verify_state "$IID_REG")"
  [ "$vs" = "reverted" ] || fail "regress: last verify_state expected reverted, got '$vs'"
  pass "auto-revert: [sim:regress] Reverted; main reverted + green again; branch kept"
else
  cat "$TMP/daemon.log" || true; fail "[sim:regress] never reached Reverted"
fi

body="$(curl -s "$BASE/api/activity")"
python3 - "$body" <<'PY' || fail "activity missing merge.revert"
import sys, json
verbs = [r.get("verb") for r in json.loads(sys.argv[1])]
assert "merge.revert" in verbs, verbs
PY
pass "GET /api/activity contains merge.revert"

# ---- stage i: SERIALIZED merges -------------------------------
# Two [sim:good] issues filed together must BOTH reach Done, leaving TWO merge
# commits on main — proving the single merger serializes across concurrent greens.
SCRATCH3="$TMP/proj3"
mkdir -p "$SCRATCH3"
git -C "$SCRATCH3" init -q -b main
git -C "$SCRATCH3" config user.email "o@example.com"
git -C "$SCRATCH3" config user.name "O Test"
cp "$SCRATCH/verify.sh" "$SCRATCH3/verify.sh"
echo "serialize project" > "$SCRATCH3/README.md"
git -C "$SCRATCH3" add -A
git -C "$SCRATCH3" commit -q -m "seed serialize project"

resp="$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Serial Co\",\"issue_prefix\":\"SER\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCH3\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST serial company expected 201, got $sc"; }
CID5="$(jget "$body" 'd["id"]')"
curl -s -X POST "$BASE/api/companies/$CID5/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Sersim","runtime":"sim"}' >/dev/null
curl -s -X POST "$BASE/api/companies/$CID5/issues" \
  -H 'Content-Type: application/json' -d '{"title":"[sim:good] first"}' >/dev/null
curl -s -X POST "$BASE/api/companies/$CID5/issues" \
  -H 'Content-Type: application/json' -d '{"title":"[sim:good] second"}' >/dev/null
IID_S1="$(jget "$(curl -s "$BASE/api/companies/$CID5/issues")" 'd[0]["id"]')"
IID_S2="$(jget "$(curl -s "$BASE/api/companies/$CID5/issues")" 'd[1]["id"]')"
[ -n "$IID_S1" ] && [ -n "$IID_S2" ] || fail "serial issue ids missing"

wait_status "$IID_S1" "Done" 120 || { cat "$TMP/daemon.log"; fail "serial issue 1 never Done"; }
wait_status "$IID_S2" "Done" 120 || { cat "$TMP/daemon.log"; fail "serial issue 2 never Done"; }
nmerge="$(git -C "$SCRATCH3" log --oneline main | grep -c "Merge branch" || true)"
[ "$nmerge" = "2" ] || { git -C "$SCRATCH3" log --oneline main; fail "serial: expected 2 merge commits, got $nmerge"; }
pass "serialization: two concurrent [sim:good] both Done, 2 merge commits on main"

# ---- stage j: DIRTY repo re-queues (no attempt consumed) ------
# Chosen "dirty" semantics: if the repo working tree has TRACKED changes when a
# merge is attempted, the merger touches nothing and reports "dirty"; the
# orchestrator logs merge.dirty and re-queues the SAME merge job (no attempt
# consumed), leaving the issue in "Verifying". Once the tree is clean the merge
# proceeds to Done. Proven here: a persistently-dirty tracked file blocks the
# merge (merge.dirty logged, issue stays Verifying), and cleaning it recovers.
SCRATCH4="$TMP/proj4"
mkdir -p "$SCRATCH4"
git -C "$SCRATCH4" init -q -b main
git -C "$SCRATCH4" config user.email "o@example.com"
git -C "$SCRATCH4" config user.name "O Test"
cp "$SCRATCH/verify.sh" "$SCRATCH4/verify.sh"
echo "dirty project" > "$SCRATCH4/README.md"
git -C "$SCRATCH4" add -A
git -C "$SCRATCH4" commit -q -m "seed dirty project"
# dirty a TRACKED file (uncommitted) — merge cannot proceed until reverted
echo "uncommitted local edit" >> "$SCRATCH4/README.md"

resp="$(curl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Dirty Co\",\"issue_prefix\":\"DRT\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCH4\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST dirty company expected 201, got $sc"; }
CID6="$(jget "$body" 'd["id"]')"
curl -s -X POST "$BASE/api/companies/$CID6/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Drtsim","runtime":"sim"}' >/dev/null
curl -s -X POST "$BASE/api/companies/$CID6/issues" \
  -H 'Content-Type: application/json' -d '{"title":"[sim:good] blocked by dirty"}' >/dev/null
IID_DRT="$(jget "$(curl -s "$BASE/api/companies/$CID6/issues")" 'd[0]["id"]')"
[ -n "$IID_DRT" ] || fail "dirty issue id missing"

# merge.dirty must appear for THIS issue while the repo stays dirty
dirty_ok=""
for _i in $(seq 1 60); do
  n="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM activity WHERE verb='merge.dirty' AND target='$IID_DRT'")"
  if [ "${n:-0}" -ge 1 ]; then dirty_ok="1"; break; fi
  sleep 1
done
[ -n "$dirty_ok" ] || { cat "$TMP/daemon.log" || true; fail "merge.dirty never logged for blocked issue"; }
# while dirty the issue must NOT terminate — it stays in the merge/verify phase
st="$(jget "$(curl -s "$BASE/api/issues/$IID_DRT")" 'd["status"]')"
[ "$st" = "Verifying" ] || fail "dirty: issue expected to stay Verifying, got '$st'"
# no attempt consumed: still on attempt 1
at="$(sqlite3 "$TMP/o.db" "SELECT attempt FROM run WHERE issue_id='$IID_DRT' ORDER BY started_at DESC LIMIT 1")"
[ "$at" = "1" ] || fail "dirty: expected attempt still 1 (no attempt consumed), got '$at'"
pass "dirty: merge.dirty re-queues, issue stays Verifying on attempt 1"

# clean the tree — the re-queued merge now proceeds to Done
git -C "$SCRATCH4" checkout -- README.md
if wait_status "$IID_DRT" "Done" 60; then
  git -C "$SCRATCH4" log --oneline main | grep "o/$IID_DRT" >/dev/null \
    || { git -C "$SCRATCH4" log --oneline main; fail "dirty: no merge commit after cleaning repo"; }
  pass "dirty: cleaned repo lets the re-queued merge complete -> Done"
else
  cat "$TMP/daemon.log" || true; fail "dirty: issue never reached Done after cleaning repo"
fi

echo
echo "ALL GREEN"
