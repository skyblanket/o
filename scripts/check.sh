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
DAEMON2_PID=""
TMP2=""
DAEMON3_PID=""
TMP3=""
DAEMON4_PID=""
TMP4=""
DAEMON5_PID=""
TMP5=""

cleanup() {
  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ -n "$DAEMON2_PID" ]; then
    kill "$DAEMON2_PID" 2>/dev/null || true
    wait "$DAEMON2_PID" 2>/dev/null || true
  fi
  if [ -n "$DAEMON3_PID" ]; then
    kill "$DAEMON3_PID" 2>/dev/null || true
    wait "$DAEMON3_PID" 2>/dev/null || true
  fi
  if [ -n "$TMP" ]; then
    rm -rf "$TMP" 2>/dev/null || true
  fi
  if [ -n "$TMP2" ]; then
    rm -rf "$TMP2" 2>/dev/null || true
  fi
  if [ -n "$DAEMON4_PID" ]; then
    kill "$DAEMON4_PID" 2>/dev/null || true
    wait "$DAEMON4_PID" 2>/dev/null || true
  fi
  if [ -n "$DAEMON5_PID" ]; then
    kill "$DAEMON5_PID" 2>/dev/null || true
    wait "$DAEMON5_PID" 2>/dev/null || true
  fi
  if [ -n "$TMP5" ]; then
    rm -rf "$TMP5" 2>/dev/null || true
  fi
  if [ -n "$TMP4" ]; then
    rm -rf "$TMP4" 2>/dev/null || true
  fi
  if [ -n "$TMP3" ]; then
    rm -rf "$TMP3" 2>/dev/null || true
  fi
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# curl with a hard wall-clock cap so a wedged connection can never hang the
# whole suite, plus ONE retry on exit 52 (swarmrt's http server occasionally
# idle-closes a keep-alive socket mid-response — a single dropped connection
# must not abort the run). All args pass straight through to curl.
ocurl() {
  local out rc
  out="$(curl --max-time 10 "$@")"; rc=$?
  if [ "$rc" = "52" ]; then
    out="$(curl --max-time 10 "$@")"; rc=$?
  fi
  printf '%s' "$out"
  return "$rc"
}

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
  code="$(ocurl -s -o /dev/null -w '%{http_code}' "$BASE/api/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then up="1"; break; fi
  sleep 0.5
done
[ -n "$up" ] || { cat "$TMP/daemon.log" || true; fail "daemon health never reached 200 (port $PORT)"; }
pass "daemon up on port $PORT (health 200)"

# ---- stage c: API smoke -------------------------------------
# create company
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Smoke Co","issue_prefix":"TST","budget_monthly_cents":100000}')"
sc="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST /api/companies expected 201, got $sc"; }
CID="$(jget "$body" 'd["id"]')"
[ -n "$CID" ] || fail "company id missing in create response"
pass "POST /api/companies -> 201 (id $CID)"

# write guards: a non-JSON write is refused (it would skip the browser's CORS
# preflight), and a preflight is only answered for a loopback Origin.
sc="$(ocurl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/companies/$CID" \
  -H 'Content-Type: text/plain' -d '{"verify_cmd":"true"}')"
[ "$sc" = "415" ] || fail "text/plain write expected 415, got $sc"
sc="$(ocurl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$BASE/api/companies/$CID" \
  -H 'Origin: https://evil.example')"
[ "$sc" = "403" ] || fail "foreign-origin preflight expected 403, got $sc"
sc="$(ocurl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$BASE/api/companies/$CID" \
  -H 'Origin: http://localhost:5173')"
[ "$sc" = "204" ] || fail "loopback preflight expected 204, got $sc"
pass "write guards: 415 non-JSON, 403 foreign preflight, 204 loopback preflight"

# create agent (sim runtime)
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies/$CID/agents" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Simmy","runtime":"sim"}')"
sc="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST agents expected 201, got $sc"; }
AID="$(jget "$body" 'd["id"]')"
[ -n "$AID" ] || fail "agent id missing in create response"
pass "POST /api/companies/:id/agents -> 201 (id $AID)"

# create issue
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies/$CID/issues" \
  -H 'Content-Type: application/json' \
  -d '{"title":"smoke"}')"
sc="$(printf '%s' "$resp" | tail -n1)"
body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST issues expected 201, got $sc"; }
IID="$(jget "$body" 'd["id"]')"
[ -n "$IID" ] || fail "issue id missing in create response"
pass "POST /api/companies/:id/issues -> 201 (id $IID)"

# ---- read each back and assert fields -----------------------
body="$(ocurl -s "$BASE/api/companies/$CID")"
python3 - "$body" <<'PY' || fail "GET company field assertions failed"
import sys, json
d = json.loads(sys.argv[1])
assert d["name"] == "Smoke Co", d.get("name")
assert d["issue_prefix"] == "TST", d.get("issue_prefix")
assert d["budget_monthly_cents"] == 100000, d.get("budget_monthly_cents")
PY
pass "GET /api/companies/:id fields (name, issue_prefix=TST, budget)"

body="$(ocurl -s "$BASE/api/companies/$CID/agents")"
python3 - "$body" "$AID" <<'PY' || fail "GET agents field assertions failed"
import sys, json
rows = json.loads(sys.argv[1]); aid = sys.argv[2]
a = next(r for r in rows if r["id"] == aid)
assert a["name"] == "Simmy", a.get("name")
assert a["runtime"] == "sim", a.get("runtime")
PY
pass "GET /api/companies/:id/agents fields (name, runtime=sim)"

body="$(ocurl -s "$BASE/api/issues/$IID")"
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
  st="$(jget "$(ocurl -s "$BASE/api/issues/$IID")" 'd["status"]' 2>/dev/null || true)"
  if [ "$st" = "Done" ]; then done_ok="1"; break; fi
  sleep 1
done
[ -n "$done_ok" ] || { cat "$TMP/daemon.log" || true; fail "issue never reached Done (last status: ${st:-none})"; }
pass "pipeline: issue $IID reached Done"

# ---- stage e: activity log has run.succeeded ----------------
body="$(ocurl -s "$BASE/api/activity")"
python3 - "$body" <<'PY' || fail "activity log missing run.succeeded"
import sys, json
rows = json.loads(sys.argv[1])
verbs = [r.get("verb") for r in rows]
assert "run.succeeded" in verbs, verbs
PY
pass "GET /api/activity contains run.succeeded"

# ---- stage e2: FEEDBACK widget intake (Phase 6b) --------------
# The widget's JS must at least parse. node is available on this box; if some
# CI lacks it, skip gracefully rather than fail the suite.
if command -v node >/dev/null 2>&1; then
  node --check feedback/o-feedback.js || fail "feedback/o-feedback.js failed node --check"
  pass "feedback/o-feedback.js passes node --check"
else
  echo "SKIP: node not found — cannot syntax-check feedback/o-feedback.js"
fi

# A dedicated company receives a 2-annotation feedback batch. The intake must
# 201 and file ONE origin='feedback' issue whose body carries the selector and
# both instructions, and log feedback.filed.
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Feedback Co","issue_prefix":"FBK","budget_monthly_cents":100000}')"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST feedback company expected 201, got $sc"; }
CIDFB="$(jget "$body" 'd["id"]')"
[ -n "$CIDFB" ] || fail "feedback company id missing"

# missing page_url -> 400
sc="$(ocurl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/companies/$CIDFB/feedback" \
  -H 'Content-Type: application/json' -d '{"annotations":[{"selector":"a","instruction":"x"}]}')"
[ "$sc" = "400" ] || fail "feedback missing page_url expected 400, got $sc"
# empty annotations -> 400
sc="$(ocurl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/companies/$CIDFB/feedback" \
  -H 'Content-Type: application/json' -d '{"page_url":"http://x/","annotations":[]}')"
[ "$sc" = "400" ] || fail "feedback empty annotations expected 400, got $sc"
pass "feedback intake: missing page_url / empty annotations both 400"

# valid 2-annotation batch -> 201
FBSEL="div.hero>h1"
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies/$CIDFB/feedback" \
  -H 'Content-Type: application/json' \
  -d '{"page_url":"http://localhost:3000/dashboard","annotations":[{"selector":"div.hero>h1","html":"<h1>Welcome</h1>","styles":{"color":"rgb(0,0,0)","font-size":"32px"},"instruction":"make the heading bigger"},{"selector":"button.cta","html":"<button>Buy</button>","styles":{"background-color":"blue"},"instruction":"change button color to green"}]}')"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST feedback batch expected 201, got $sc"; }
IIDFB="$(jget "$body" 'd["id"]')"
[ -n "$IIDFB" ] || fail "feedback issue id missing"
pass "POST /api/companies/:id/feedback (2 annotations) -> 201 (issue $IIDFB)"

# GET the issue back: origin 'feedback', body carries selector + both instructions
body="$(ocurl -s "$BASE/api/issues/$IIDFB")"
python3 - "$body" "$FBSEL" <<'PY' || fail "feedback issue field/body assertions failed"
import sys, json
d = json.loads(sys.argv[1]); sel = sys.argv[2]
assert d["origin"] == "feedback", d.get("origin")
b = d.get("body", "")
assert sel in b, "selector not in body"
assert "make the heading bigger" in b, "instruction 1 not in body"
assert "change button color to green" in b, "instruction 2 not in body"
assert "2 annotation" in b, "annotation count not in body"
PY
pass "feedback issue: origin=feedback, body has selector + both instructions"

# activity has feedback.filed for this issue
body="$(ocurl -s "$BASE/api/activity")"
python3 - "$body" "$IIDFB" <<'PY' || fail "activity missing feedback.filed"
import sys, json
rows = json.loads(sys.argv[1]); iid = sys.argv[2]
hit = [r for r in rows if r.get("verb") == "feedback.filed" and r.get("target") == iid]
assert hit, "no feedback.filed for issue"
assert hit[0].get("actor") == "feedback-widget", hit[0].get("actor")
PY
pass "GET /api/activity contains feedback.filed (actor feedback-widget)"

# ---- stage f: daily budget ledger — pause + rollover ---------
# A company with budget_daily_cents=100 and a sim agent (each run
# costs 300) must hard-stop on the DAILY cap after its first run,
# with pause_reason="budget-daily". Rewinding budget_day by one day
# then makes the next tick's rollover reset spent_today and un-pause.
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
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

ocurl -s -X POST "$BASE/api/companies/$CID2/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Dailysim","runtime":"sim"}' >/dev/null
ocurl -s -X POST "$BASE/api/companies/$CID2/issues" \
  -H 'Content-Type: application/json' -d '{"title":"burn"}' >/dev/null

# Wait for the daily cap to hard-stop the company.
paused_ok=""
for _i in $(seq 1 60); do
  body="$(ocurl -s "$BASE/api/companies/$CID2")"
  st="$(jget "$body" 'd["status"]' 2>/dev/null || true)"
  if [ "$st" = "paused" ]; then paused_ok="1"; break; fi
  sleep 1
done
[ -n "$paused_ok" ] || { cat "$TMP/daemon.log" || true; fail "daily-budget company never paused (last status: ${st:-none})"; }
body="$(ocurl -s "$BASE/api/companies/$CID2")"
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
IID2="$(jget "$(ocurl -s "$BASE/api/companies/$CID2/issues")" 'd[0]["id"]')"
ocurl -s -X POST "$BASE/api/issues/$IID2" \
  -H 'Content-Type: application/json' -d '{"status":"Canceled"}' >/dev/null

# Rewind the ledger day; the next tick's rollover must reset + un-pause.
sqlite3 "$TMP/o.db" "UPDATE company SET budget_day = budget_day - 1 WHERE id='$CID2'"

rolled_ok=""
for _i in $(seq 1 20); do
  body="$(ocurl -s "$BASE/api/companies/$CID2")"
  st="$(jget "$body" 'd["status"]' 2>/dev/null || true)"
  sp="$(jget "$body" 'd["spent_today_cents"]' 2>/dev/null || true)"
  if [ "$st" = "active" ] && [ "$sp" = "0" ]; then rolled_ok="1"; break; fi
  sleep 1
done
[ -n "$rolled_ok" ] || { cat "$TMP/daemon.log" || true; fail "rollover never reset company $CID2 (status=${st:-none} spent_today=${sp:-none})"; }
pass "rollover: company $CID2 active again, spent_today_cents=0"

body="$(ocurl -s "$BASE/api/activity")"
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
mkdir -p "$SCRATCH/protected"
echo "fenced" > "$SCRATCH/protected/keep.txt"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" commit -q -m "seed verify project"

# company wired to the scratch repo + verify command + a protected prefix
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
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

ocurl -s -X POST "$BASE/api/companies/$CID3/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Versim","runtime":"sim"}' >/dev/null
pass "verify-gate sim agent hired"

# fire all four marker issues up front so they process concurrently
mk_issue() {
  local resp
  resp="$(ocurl -s -X POST "$BASE/api/companies/$CID3/issues" \
    -H 'Content-Type: application/json' -d "{\"title\":\"$1\"}")"
  jget "$resp" 'd["id"]'
}
IID_GOOD="$(mk_issue '[sim:good] add file')"
IID_NC="$(mk_issue '[sim:no-commit] nothing')"
IID_PROT="$(mk_issue '[sim:protected] sneaky')"
IID_BAD="$(mk_issue '[sim:bad-verify] break')"
IID_REN="$(mk_issue '[sim:protected-rename] move it out')"
for x in "$IID_GOOD" "$IID_NC" "$IID_PROT" "$IID_BAD" "$IID_REN"; do
  [ -n "$x" ] || fail "verify-gate issue id missing"
done
pass "verify-gate issues created (good/no-commit/protected/bad-verify)"

# wait_status <iid> <want> <max-seconds>
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

# wait_status_at <base> <iid> <want> <max-seconds> — like wait_status but
# against an explicit daemon base URL (the phase-4 stages boot a 2nd daemon).
wait_status_at() {
  local st=""
  for _i in $(seq 1 "$4"); do
    st="$(jget "$(ocurl -s "$1/api/issues/$2")" 'd["status"]' 2>/dev/null || true)"
    if [ "$st" = "$3" ]; then return 0; fi
    sleep 1
  done
  echo "  last status of $2: ${st:-none}"
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
rr="$(ocurl -s "$BASE/api/runs/$RID_GOOD/result")"
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

# [sim:protected-rename] — git mv a protected file OUT of the fence. Rename
# detection would list only the new path; the gate must still see the delete.
if wait_status "$IID_REN" "Failed" 120; then
  vs="$(last_verify_state "$IID_REN")"
  [ "$vs" = "red_protected" ] || fail "[sim:protected-rename] last verify_state expected red_protected, got '$vs'"
  pass "verify-gate: [sim:protected-rename] Failed with verify_state=red_protected"
else
  cat "$TMP/daemon.log" || true; fail "[sim:protected-rename] never reached Failed"
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
body="$(ocurl -s "$BASE/api/activity")"
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

resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Regress Co\",\"issue_prefix\":\"REG\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCH2\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST regress company expected 201, got $sc"; }
CID4="$(jget "$body" 'd["id"]')"
ocurl -s -X POST "$BASE/api/companies/$CID4/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Regsim","runtime":"sim"}' >/dev/null
ocurl -s -X POST "$BASE/api/companies/$CID4/issues" \
  -H 'Content-Type: application/json' -d '{"title":"[sim:regress] boom"}' >/dev/null
IID_REG="$(jget "$(ocurl -s "$BASE/api/companies/$CID4/issues")" 'd[0]["id"]')"
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

body="$(ocurl -s "$BASE/api/activity")"
python3 - "$body" <<'PY' || fail "activity missing merge.revert"
import sys, json
verbs = [r.get("verb") for r in json.loads(sys.argv[1])]
assert "merge.revert" in verbs, verbs
PY
pass "GET /api/activity contains merge.revert"

# ---- stage h2: SELF-FILED revert-fix issue --------------------
# The post-merge revert must auto-file exactly ONE origin='auto', high-priority
# fix issue fingerprinted "revert:<ident>" (ident = the reverted issue's Linear
# identifier), pointing at the kept branch. Poll: issue_set_status(Reverted)
# and issue_create_auto commit on separate autocommit statements, so the API
# can momentarily see "Reverted" a beat before the auto-file lands.
REG_IDENT="$(sqlite3 "$TMP/o.db" "SELECT identifier FROM issue WHERE id='$IID_REG'")"
[ -n "$REG_IDENT" ] || fail "revert self-file: could not read reverted issue identifier"
selffile_ok=""
for _i in $(seq 1 15); do
  nrev="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CID4' AND fingerprint='revert:$REG_IDENT' AND origin='auto' AND priority='high'")"
  if [ "${nrev:-0}" = "1" ]; then selffile_ok="1"; break; fi
  sleep 1
done
[ -n "$selffile_ok" ] || { cat "$TMP/daemon.log" || true; fail "revert self-file: expected exactly 1 origin=auto high revert:$REG_IDENT issue, got ${nrev:-0}"; }
sfbody="$(sqlite3 "$TMP/o.db" "SELECT body FROM issue WHERE company_id='$CID4' AND fingerprint='revert:$REG_IDENT'")"
printf '%s' "$sfbody" | grep -q "o/$IID_REG" || fail "revert self-file: body does not name kept branch o/$IID_REG"
sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM activity WHERE verb='selffile.created' AND target='revert:$REG_IDENT'" | grep -q '^1$' \
  || fail "revert self-file: selffile.created not logged for revert:$REG_IDENT"
pass "self-file: revert auto-filed exactly one origin=auto high issue (revert:$REG_IDENT), branch named, selffile.created logged"

# ---- stage i: SERIALIZED merges -------------------------------
# Two [sim:good] issues filed together must BOTH reach Done, leaving TWO merge
# commits on main — proving the single merger serializes across concurrent greens.
SCRATCH3="$TMP/serial proj"  # a space: every git/verify call must quote the repo path
mkdir -p "$SCRATCH3"
git -C "$SCRATCH3" init -q -b main
git -C "$SCRATCH3" config user.email "o@example.com"
git -C "$SCRATCH3" config user.name "O Test"
cp "$SCRATCH/verify.sh" "$SCRATCH3/verify.sh"
echo "serialize project" > "$SCRATCH3/README.md"
git -C "$SCRATCH3" add -A
git -C "$SCRATCH3" commit -q -m "seed serialize project"

resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Serial Co\",\"issue_prefix\":\"SER\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCH3\",\"verify_cmd\":\"sh verify.sh && [ 'x y' = 'x y' ]\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST serial company expected 201, got $sc"; }
CID5="$(jget "$body" 'd["id"]')"
ocurl -s -X POST "$BASE/api/companies/$CID5/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Sersim","runtime":"sim"}' >/dev/null
ocurl -s -X POST "$BASE/api/companies/$CID5/issues" \
  -H 'Content-Type: application/json' -d '{"title":"[sim:good] first"}' >/dev/null
ocurl -s -X POST "$BASE/api/companies/$CID5/issues" \
  -H 'Content-Type: application/json' -d '{"title":"[sim:good] second"}' >/dev/null
IID_S1="$(jget "$(ocurl -s "$BASE/api/companies/$CID5/issues")" 'd[0]["id"]')"
IID_S2="$(jget "$(ocurl -s "$BASE/api/companies/$CID5/issues")" 'd[1]["id"]')"
[ -n "$IID_S1" ] && [ -n "$IID_S2" ] || fail "serial issue ids missing"

wait_status "$IID_S1" "Done" 120 || { cat "$TMP/daemon.log"; fail "serial issue 1 never Done"; }
wait_status "$IID_S2" "Done" 120 || { cat "$TMP/daemon.log"; fail "serial issue 2 never Done"; }
nmerge="$(git -C "$SCRATCH3" log --oneline main | grep -c "Merge branch" || true)"
[ "$nmerge" = "2" ] || { git -C "$SCRATCH3" log --oneline main; fail "serial: expected 2 merge commits, got $nmerge"; }
pass "serialization: two concurrent [sim:good] both Done, 2 merge commits on main (repo path has a space, verify_cmd has quotes)"

# ---- stage i2: FLAKY post-merge verify re-runs before reverting ---
# verify.sh fails exactly ONCE on main (no PROMPT.txt there; the flag file
# lives outside the repo). The worktree verify is green, the first post-merge
# verify is red, the re-run is green -> Done (not Reverted) + merge.flaky.
SCRATCHF="$TMP/projf"
mkdir -p "$SCRATCHF"
git -C "$SCRATCHF" init -q -b main
git -C "$SCRATCHF" config user.email "o@example.com"
git -C "$SCRATCHF" config user.name "O Test"
cat > "$SCRATCHF/verify.sh" <<SH
#!/bin/sh
if [ ! -f PROMPT.txt ] && [ ! -f "$TMP/flaked" ]; then touch "$TMP/flaked"; echo "flake"; exit 1; fi
exit 0
SH
echo "flaky project" > "$SCRATCHF/README.md"
git -C "$SCRATCHF" add -A
git -C "$SCRATCHF" commit -q -m "seed flaky project"
resp="$(ocurl -s -X POST "$BASE/api/companies" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Flaky Co\",\"issue_prefix\":\"FLK\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCHF\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
CIDF="$(jget "$resp" 'd["id"]')"
ocurl -s -X POST "$BASE/api/companies/$CIDF/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Flksim","runtime":"sim"}' >/dev/null
IID_FLK="$(jget "$(ocurl -s -X POST "$BASE/api/companies/$CIDF/issues" -H 'Content-Type: application/json' -d '{"title":"[sim:good] survives a flake"}')" 'd["id"]')"
wait_status "$IID_FLK" "Done" 120 || { cat "$TMP/daemon.log"; fail "flaky: issue never Done (reverted on a single flake?)"; }
[ -f "$TMP/flaked" ] || fail "flaky: the post-merge verify never flaked (test is not exercising the re-run)"
nfl="$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM activity WHERE verb='merge.flaky' AND target='$IID_FLK'")"
[ "$nfl" = "1" ] || fail "flaky: expected one merge.flaky, got $nfl"
pass "flaky: one red post-merge verify re-runs green -> Done + merge.flaky (no revert)"

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

resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Dirty Co\",\"issue_prefix\":\"DRT\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCH4\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST dirty company expected 201, got $sc"; }
CID6="$(jget "$body" 'd["id"]')"
ocurl -s -X POST "$BASE/api/companies/$CID6/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Drtsim","runtime":"sim"}' >/dev/null
ocurl -s -X POST "$BASE/api/companies/$CID6/issues" \
  -H 'Content-Type: application/json' -d '{"title":"[sim:good] blocked by dirty"}' >/dev/null
IID_DRT="$(jget "$(ocurl -s "$BASE/api/companies/$CID6/issues")" 'd[0]["id"]')"
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
st="$(jget "$(ocurl -s "$BASE/api/issues/$IID_DRT")" 'd["status"]')"
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

# ---- stage j2: CRASH RECOVERY keeps attempt counts -------------
# The retry map is in memory. Simulate a daemon dying mid-run: stop it, plant
# two issues stuck "In Progress" with orphaned Running runs, restart on the
# same DB. One already spent all 3 attempts -> Failed without re-running; one
# spent 1 -> re-dispatched as attempt 2 (not 1) and finishes Done.
kill "$DAEMON_PID" 2>/dev/null || true; wait "$DAEMON_PID" 2>/dev/null || true
AG1="$(sqlite3 "$TMP/o.db" "SELECT id FROM agent WHERE company_id='$CID' LIMIT 1")"
now_ms="$(($(date +%s) * 1000))"
sqlite3 "$TMP/o.db" <<SQL
INSERT INTO issue (id, company_id, identifier, title, body, status, priority, sort_order, created_at, updated_at, origin)
  VALUES ('iss_rec_spent', '$CID', 'TST-R1', 'recovered spent', '', 'In Progress', 'medium', 101, $now_ms, $now_ms, 'operator'),
         ('iss_rec_one',   '$CID', 'TST-R2', 'recovered one',   '', 'In Progress', 'medium', 103, $now_ms, $now_ms, 'operator');
INSERT INTO run (id, issue_id, agent_id, attempt, state, started_at) VALUES
  ('run_rec_a', 'iss_rec_spent', '$AG1', 1, 'Failed',  $now_ms - 3),
  ('run_rec_b', 'iss_rec_spent', '$AG1', 2, 'Failed',  $now_ms - 2),
  ('run_rec_c', 'iss_rec_spent', '$AG1', 3, 'Running', $now_ms - 1),
  ('run_rec_d', 'iss_rec_one',   '$AG1', 1, 'Running', $now_ms - 1);
SQL
HOME="$TMP" O_DB="$TMP/o.db" O_PORT="$PORT" O_NO_OPEN=1 ./bin/swarmd >>"$TMP/daemon.log" 2>&1 &
DAEMON_PID=$!
up=""
for _i in $(seq 1 40); do
  code="$(ocurl -s -o /dev/null -w '%{http_code}' "$BASE/api/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then up="1"; break; fi
  sleep 0.5
done
[ -n "$up" ] || { tail -20 "$TMP/daemon.log"; fail "restarted daemon never came up"; }
wait_status "iss_rec_spent" "Failed" 30 || fail "recovery: issue with 3 spent attempts was not Failed"
[ "$(sqlite3 "$TMP/o.db" "SELECT COUNT(*) FROM run WHERE issue_id='iss_rec_spent'")" = "3" ] \
  || fail "recovery: exhausted issue was re-run after restart"
[ "$(sqlite3 "$TMP/o.db" "SELECT state FROM run WHERE id='run_rec_c'")" = "Abandoned" ] \
  || fail "recovery: orphaned Running run not marked Abandoned"
wait_status "iss_rec_one" "Done" 60 || { tail -20 "$TMP/daemon.log"; fail "recovery: issue with 1 spent attempt never Done"; }
[ "$(sqlite3 "$TMP/o.db" "SELECT MIN(attempt) FROM run WHERE issue_id='iss_rec_one' AND id != 'run_rec_d'")" = "2" ] \
  || fail "recovery: re-dispatch did not continue at attempt 2"
pass "recovery: restart keeps attempt counts (exhausted -> Failed, partial -> attempt 2), orphan run Abandoned"

# ============================================================
# Phase-4 stages — self-feedback loop (2nd daemon, tight breakers)
# ============================================================
# A second daemon with O_SELF_FILE_CAP=2 + O_NO_SIGNAL_DAYS=2 so the auto-file
# daily cap and the no-signal breaker fire quickly and observably.
TMP2="$(mktemp -d)"
PORT2=$((4650 + RANDOM % 300))
BASE2="http://127.0.0.1:${PORT2}"
HOME="$TMP2" O_DB="$TMP2/o.db" O_PORT="$PORT2" O_NO_OPEN=1 O_SELF_FILE_CAP=2 O_NO_SIGNAL_DAYS=2 \
  ./bin/swarmd >"$TMP2/daemon.log" 2>&1 &
DAEMON2_PID=$!
up2=""
for _i in $(seq 1 30); do
  if ! kill -0 "$DAEMON2_PID" 2>/dev/null; then cat "$TMP2/daemon.log" || true; fail "daemon2 exited during boot"; fi
  code="$(ocurl -s -o /dev/null -w '%{http_code}' "$BASE2/api/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then up2="1"; break; fi
  sleep 0.5
done
[ -n "$up2" ] || { cat "$TMP2/daemon.log" || true; fail "daemon2 health never reached 200 (port $PORT2)"; }
pass "phase4 daemon up on port $PORT2 (O_SELF_FILE_CAP=2, O_NO_SIGNAL_DAYS=2)"

# A scratch repo so a succeeded sim run enters the verify gate. [sim:no-commit]
# fails at red_no_commit (BEFORE the verify command runs) — the cleanest way to
# drive an issue to a final verify fail (and thus a verify-final auto-file).
SCRATCHK="$TMP2/projk"
mkdir -p "$SCRATCHK"
git -C "$SCRATCHK" init -q -b main
git -C "$SCRATCHK" config user.email "o@example.com"
git -C "$SCRATCHK" config user.name "O Test"
cp "$SCRATCH/verify.sh" "$SCRATCHK/verify.sh"
echo "self-file project" > "$SCRATCHK/README.md"
git -C "$SCRATCHK" add -A
git -C "$SCRATCHK" commit -q -m "seed self-file project"

mkco2() {  # <name> <prefix> -> company id on daemon2 (wired to SCRATCHK)
  local resp sc body
  resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE2/api/companies" \
    -H 'Content-Type: application/json' \
    -d "{\"name\":\"$1\",\"issue_prefix\":\"$2\",\"budget_monthly_cents\":100000000,\"repo\":\"$SCRATCHK\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
  sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
  [ "$sc" = "201" ] || { echo "$body" >&2; return 1; }
  jget "$body" 'd["id"]'
}
mkissue2() {  # <cid> <title> -> issue id
  jget "$(ocurl -s -X POST "$BASE2/api/companies/$1/issues" -H 'Content-Type: application/json' -d "{\"title\":\"$2\"}")" 'd["id"]'
}

# ---- stage k: SELF-FILE — depth-1 + daily cap -----------------
# Two separate companies so their per-company caps don't interfere.
CID_K1="$(mkco2 'DepthOne Co' 'DP1')"; [ -n "$CID_K1" ] || fail "depth-1 company create failed"
ocurl -s -X POST "$BASE2/api/companies/$CID_K1/agents" -H 'Content-Type: application/json' -d '{"name":"Dpsim","runtime":"sim"}' >/dev/null
CID_K2="$(mkco2 'Cap Co' 'CAP')"; [ -n "$CID_K2" ] || fail "cap company create failed"
ocurl -s -X POST "$BASE2/api/companies/$CID_K2/agents" -H 'Content-Type: application/json' -d '{"name":"Capsim","runtime":"sim"}' >/dev/null

# depth-1: an issue we mark origin='auto' — its own final fail must file NO child.
IID_K1="$(mkissue2 "$CID_K1" '[sim:no-commit] depth one')"
[ -n "$IID_K1" ] || fail "depth-1 issue create failed"
sqlite3 "$TMP2/o.db" "UPDATE issue SET origin='auto' WHERE id='$IID_K1'"

# cap: THREE ordinary no-commit issues — with cap=2, two verify-final children
# are filed and the third auto-file is capped.
IID_C1="$(mkissue2 "$CID_K2" '[sim:no-commit] one')"
IID_C2="$(mkissue2 "$CID_K2" '[sim:no-commit] two')"
IID_C3="$(mkissue2 "$CID_K2" '[sim:no-commit] three')"
for x in "$IID_C1" "$IID_C2" "$IID_C3"; do [ -n "$x" ] || fail "cap issue id missing"; done

# all four parents must reach Failed (they run concurrently, cap 3)
wait_status_at "$BASE2" "$IID_K1" "Failed" 200 || { cat "$TMP2/daemon.log" || true; fail "depth-1 [sim:no-commit] never Failed"; }
wait_status_at "$BASE2" "$IID_C1" "Failed" 200 || { cat "$TMP2/daemon.log" || true; fail "cap issue 1 never Failed"; }
wait_status_at "$BASE2" "$IID_C2" "Failed" 200 || { cat "$TMP2/daemon.log" || true; fail "cap issue 2 never Failed"; }
wait_status_at "$BASE2" "$IID_C3" "Failed" 200 || { cat "$TMP2/daemon.log" || true; fail "cap issue 3 never Failed"; }

# depth-1 assertions: no child filed off the origin=auto issue, skip logged.
K1_IDENT="$(sqlite3 "$TMP2/o.db" "SELECT identifier FROM issue WHERE id='$IID_K1'")"
depth_ok=""
for _i in $(seq 1 15); do
  ndepth="$(sqlite3 "$TMP2/o.db" "SELECT COUNT(*) FROM activity WHERE verb='selffile.skipped_depth' AND target='$K1_IDENT'")"
  [ "${ndepth:-0}" -ge 1 ] && { depth_ok="1"; break; }
  sleep 1
done
[ -n "$depth_ok" ] || { cat "$TMP2/daemon.log" || true; fail "depth-1: selffile.skipped_depth not logged for $K1_IDENT"; }
nchild="$(sqlite3 "$TMP2/o.db" "SELECT COUNT(*) FROM issue WHERE fingerprint='verify-final:$K1_IDENT'")"
[ "$nchild" = "0" ] || fail "depth-1: a child issue was filed off an origin=auto issue (fork-bomb guard failed), got $nchild"
pass "self-file depth-1: an origin=auto issue's final fail files NO child (selffile.skipped_depth logged)"

# cap assertions: exactly 2 verify-final children filed, the 3rd capped.
cap_ok=""
for _i in $(seq 1 25); do
  nauto="$(sqlite3 "$TMP2/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CID_K2' AND origin='auto' AND fingerprint LIKE 'verify-final:%'")"
  ncap="$(sqlite3 "$TMP2/o.db" "SELECT COUNT(*) FROM activity WHERE company_id='$CID_K2' AND verb='selffile.capped'")"
  if [ "${nauto:-0}" = "2" ] && [ "${ncap:-0}" -ge 1 ]; then cap_ok="1"; break; fi
  sleep 1
done
[ -n "$cap_ok" ] || { echo "nauto=${nauto:-?} ncap=${ncap:-?}"; cat "$TMP2/daemon.log" || true; fail "cap: expected exactly 2 auto verify-final issues + >=1 selffile.capped"; }
ncreated="$(sqlite3 "$TMP2/o.db" "SELECT COUNT(*) FROM activity WHERE company_id='$CID_K2' AND verb='selffile.created'")"
[ "${ncreated:-0}" = "2" ] || fail "cap: expected exactly 2 selffile.created, got ${ncreated:-0}"
pass "self-file cap: 3 verify-final fails under cap=2 -> 2 filed, 1 capped (selffile.created x2, selffile.capped)"

# ---- stage l: NO-SIGNAL breaker -------------------------------
# Seed a company that spent >=80% of its daily budget with zero greens on a
# stale day; each rollover bumps no_signal_days. At O_NO_SIGNAL_DAYS=2 the 2nd
# such rollover pauses it (pause_reason='no-signal') and auto-files a
# diagnostic. No agents: the seeded counters are the only signal.
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE2/api/companies" \
  -H 'Content-Type: application/json' \
  -d '{"name":"NoSignal Co","issue_prefix":"NOS","budget_daily_cents":1000}')"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST no-signal company expected 201, got $sc"; }
CID_L="$(jget "$body" 'd["id"]')"
[ -n "$CID_L" ] || fail "no-signal company id missing"

DAY_MINUS1="(strftime('%s','now')*1000/86400000)-1"
# day 1: 900/1000 spent, 0 greens, stamped yesterday -> next rollover bumps to 1
sqlite3 "$TMP2/o.db" "UPDATE company SET budget_daily_cents=1000, spent_today_cents=900, greens_today=0, no_signal_days=0, status='active', pause_reason='', budget_day=$DAY_MINUS1 WHERE id='$CID_L'"
ns1_ok=""
for _i in $(seq 1 20); do
  n="$(sqlite3 "$TMP2/o.db" "SELECT no_signal_days FROM company WHERE id='$CID_L'")"
  sp="$(sqlite3 "$TMP2/o.db" "SELECT spent_today_cents FROM company WHERE id='$CID_L'")"
  if [ "${n:-x}" = "1" ] && [ "${sp:-x}" = "0" ]; then ns1_ok="1"; break; fi
  sleep 1
done
[ -n "$ns1_ok" ] || { cat "$TMP2/daemon.log" || true; fail "no-signal: first rollover expected no_signal_days=1 spent_today=0 (got n=${n:-?} sp=${sp:-?})"; }
st="$(jget "$(ocurl -s "$BASE2/api/companies/$CID_L")" 'd["status"]')"
[ "$st" = "active" ] || fail "no-signal: company should still be active after day 1 (got $st)"
pass "no-signal: day-1 rollover bumped no_signal_days=1, reset spend, still active"

# day 2: spend high again with zero greens, stale day -> rollover to 2 -> pause
sqlite3 "$TMP2/o.db" "UPDATE company SET spent_today_cents=900, greens_today=0, budget_day=$DAY_MINUS1 WHERE id='$CID_L'"
paused2_ok=""
for _i in $(seq 1 20); do
  body="$(ocurl -s "$BASE2/api/companies/$CID_L")"
  st="$(jget "$body" 'd["status"]' 2>/dev/null || true)"
  pr="$(jget "$body" 'd["pause_reason"]' 2>/dev/null || true)"
  if [ "$st" = "paused" ] && [ "$pr" = "no-signal" ]; then paused2_ok="1"; break; fi
  sleep 1
done
[ -n "$paused2_ok" ] || { cat "$TMP2/daemon.log" || true; fail "no-signal: 2nd rollover expected paused/no-signal (got status=${st:-?} reason=${pr:-?})"; }
ndiag="$(sqlite3 "$TMP2/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CID_L' AND fingerprint='no-signal:$CID_L' AND origin='auto'")"
[ "$ndiag" = "1" ] || fail "no-signal: expected exactly 1 diagnostic issue no-signal:$CID_L, got $ndiag"
sqlite3 "$TMP2/o.db" "SELECT COUNT(*) FROM activity WHERE company_id='$CID_L' AND verb='budget.no_signal'" | grep -q '^1$' \
  || fail "no-signal: budget.no_signal not logged exactly once"
pass "no-signal: 2nd rollover paused company (pause_reason=no-signal), diagnostic filed, budget.no_signal logged"

# ============================================================
# Phase-5 stage — daily reflection pass (3rd daemon, O_REFLECT=1)
# ============================================================
# A dedicated daemon with O_REFLECT=1 and a STUB claude binary. The stub
# ignores its args, reads the prompt on stdin, files ONE reflect-origin issue
# back through the daemon's REST API (the endpoint URL is scraped out of the
# prompt), then emits a single stream-json result line reporting $0.05. The
# company has a repo + verify_cmd but NO agent — so dispatch skips it and the
# stage stays deterministic (nothing consumes the reflect-filed Backlog issue).
TMP3="$(mktemp -d)"
PORT3=$((4980 + RANDOM % 300))
BASE3="http://127.0.0.1:${PORT3}"

# The stub stands in for `claude -p`. It scrapes the /issues endpoint out of
# the piped prompt and POSTs one reflect-origin issue, then prints the final
# {type:result} event carrying a fixed $0.05 cost (parse_stream_cost -> 5c).
cat > "$TMP3/claude-stub" <<'STUB'
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
chmod +x "$TMP3/claude-stub"

HOME="$TMP3" O_DB="$TMP3/o.db" O_PORT="$PORT3" O_NO_OPEN=1 O_REFLECT=1 \
  O_CLAUDE_BIN="$TMP3/claude-stub" ./bin/swarmd >"$TMP3/daemon.log" 2>&1 &
DAEMON3_PID=$!
up3=""
for _i in $(seq 1 30); do
  if ! kill -0 "$DAEMON3_PID" 2>/dev/null; then cat "$TMP3/daemon.log" || true; fail "daemon3 exited during boot"; fi
  code="$(ocurl -s -o /dev/null -w '%{http_code}' "$BASE3/api/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then up3="1"; break; fi
  sleep 0.5
done
[ -n "$up3" ] || { cat "$TMP3/daemon.log" || true; fail "daemon3 health never reached 200 (port $PORT3)"; }
pass "phase5 daemon up on port $PORT3 (O_REFLECT=1, stub claude)"

# A scratch repo so the company qualifies for reflection (repo != '').
SCRATCHR="$TMP3/projr"
mkdir -p "$SCRATCHR"
git -C "$SCRATCHR" init -q -b main
git -C "$SCRATCHR" config user.email "o@example.com"
git -C "$SCRATCHR" config user.name "O Test"
cp "$SCRATCH/verify.sh" "$SCRATCHR/verify.sh"
echo "reflect project" > "$SCRATCHR/README.md"
git -C "$SCRATCHR" add -A
git -C "$SCRATCHR" commit -q -m "seed reflect project"

# Company WITH repo + verify_cmd but deliberately NO agent. A fresh company has
# last_reflect_day=0 < today, so the very next tick reflects exactly once.
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE3/api/companies" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Reflect Co\",\"issue_prefix\":\"RFL\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCHR\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST reflect company expected 201, got $sc"; }
CID_R="$(jget "$body" 'd["id"]')"
[ -n "$CID_R" ] || fail "reflect company id missing"
pass "phase5: reflect company $CID_R created (repo wired, no agent)"

# Within a few ticks: reflect.spawn, reflect.filed and reflect.done all logged.
reflect_ok=""
for _i in $(seq 1 40); do
  nsp="$(sqlite3 "$TMP3/o.db" "SELECT COUNT(*) FROM activity WHERE company_id='$CID_R' AND verb='reflect.spawn'")"
  nfl="$(sqlite3 "$TMP3/o.db" "SELECT COUNT(*) FROM activity WHERE company_id='$CID_R' AND verb='reflect.filed'")"
  ndn="$(sqlite3 "$TMP3/o.db" "SELECT COUNT(*) FROM activity WHERE company_id='$CID_R' AND verb='reflect.done'")"
  if [ "${nsp:-0}" -ge 1 ] && [ "${nfl:-0}" -ge 1 ] && [ "${ndn:-0}" -ge 1 ]; then reflect_ok="1"; break; fi
  sleep 1
done
[ -n "$reflect_ok" ] || { cat "$TMP3/daemon.log" || true; fail "reflect: expected reflect.spawn/filed/done (spawn=${nsp:-?} filed=${nfl:-?} done=${ndn:-?})"; }
pass "reflect: reflect.spawn, reflect.filed and reflect.done all logged"

# Exactly ONE reflect-origin issue was filed.
nref="$(sqlite3 "$TMP3/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CID_R' AND origin='reflect'")"
[ "$nref" = "1" ] || { cat "$TMP3/daemon.log" || true; fail "reflect: expected exactly 1 origin=reflect issue, got ${nref}"; }
pass "reflect: exactly one origin=reflect issue filed"

# The stub's $0.05 was accounted onto the company (spent_today_cents == 5). The
# agentless company runs nothing else, so 5 is the only spend.
sp="$(jget "$(ocurl -s "$BASE3/api/companies/$CID_R")" 'd["spent_today_cents"]')"
[ "$sp" = "5" ] || { cat "$TMP3/daemon.log" || true; fail "reflect: expected spent_today_cents=5 (0.05*100), got ${sp}"; }
pass "reflect: reflection cost accounted (spent_today_cents=5)"

# Reflection is at-most-once per day: last_reflect_day is stamped to today, and
# only one reflect.spawn ever fires even across many subsequent ticks.
sleep 6
nsp2="$(sqlite3 "$TMP3/o.db" "SELECT COUNT(*) FROM activity WHERE company_id='$CID_R' AND verb='reflect.spawn'")"
[ "$nsp2" = "1" ] || fail "reflect: expected exactly 1 reflect.spawn (at-most-once/day), got ${nsp2}"
pass "reflect: at-most-once per day (single reflect.spawn after extra ticks)"

# ============================================================
# Review gate — 4th daemon, O_REVIEW=1, stub reviewer
# ============================================================
# The stub stands in for `claude -p`: it reads the review prompt on stdin and
# REJECTs when the issue title carries [review:reject], else APPROVEs, always
# reporting $0.01. A [sim:good] change passes verify either way, so the
# reviewer alone decides: approve -> merged Done; reject -> red_review on every
# attempt -> Failed, with the reviewer's reason recorded as the verify tail.
TMP4="$(mktemp -d)"
PORT4=$((5300 + RANDOM % 300))
BASE4="http://127.0.0.1:${PORT4}"
cat > "$TMP4/claude-stub" <<'STUB'
#!/bin/sh
in="$(cat)"
case "$in" in
  *"[review:reject]"*) printf '%s' '{"type":"result","result":"REJECT: stub reviewer says the change is wrong","total_cost_usd":0.01}' ;;
  *) printf '%s' '{"type":"result","result":"APPROVE","total_cost_usd":0.01}' ;;
esac
STUB
chmod +x "$TMP4/claude-stub"
# gh stub: a bare repo stands in for GitHub. `pr merge` really merges the
# branch into the bare repo's main; checks fail for branches listed in
# $GHS/fail_ci; merges are refused for branches listed in $GHS/block_merge.
cat > "$TMP4/gh-stub" <<'STUB'
#!/bin/sh
sub="$1 $2"; shift 2
branch=""; json=""; bodyf=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--base|--title|--label|--state|--limit) shift ;;
    --head) branch="$2"; shift ;;
    --json) json="$2"; shift ;;
    --body-file) bodyf="$2"; shift ;;
    --*) ;;
    *) [ -z "$branch" ] && branch="$1" ;;
  esac
  shift
done
key="$(printf '%s' "$branch" | tr '/' '_')"
listed() { [ -f "$GHS/$1" ] && grep -qx "$branch" "$GHS/$1"; }
case "$sub" in
  "issue list") cat "$GHS/issues.json" ;;
  "pr create") cp "$bodyf" "$GHS/body_$key"; echo "https://example.test/pr/$key" ;;
  "pr merge")
    listed block_merge && { echo "base branch policy prohibits the merge" >&2; exit 1; }
    tmp="$(mktemp -d)"; git clone -q "$GHS/remote.git" "$tmp/c" && cd "$tmp/c" \
      && git -c user.email=gh@x -c user.name=gh merge -q --no-ff --no-edit "origin/$branch" \
      && git push -q origin main && git push -q origin --delete "$branch" && touch "$GHS/merged_$key" ;;
  "pr view")
    case "$json" in
      number,url) [ -f "$GHS/body_$key" ] || exit 1; echo '{"number":1,"url":"https://example.test/pr"}' ;;
      mergeCommit) echo '{"mergeCommit":{"oid":"0000000"}}' ;;
      *) if listed fail_ci; then c='"FAILURE"'; else c='"SUCCESS"'; fi
         echo "{\"state\":\"OPEN\",\"mergeable\":\"MERGEABLE\",\"statusCheckRollup\":[{\"name\":\"build\",\"status\":\"COMPLETED\",\"conclusion\":$c}]}" ;;
    esac ;;
  *) echo "gh-stub: unhandled $sub" >&2; exit 2 ;;
esac
STUB
chmod +x "$TMP4/gh-stub"
# The same daemon also carries the GitHub stub (stage below): fast polls, no
# CI settle wait. GHS is the stub's state dir.
GHS="$TMP4/ghs"; mkdir -p "$GHS"; echo '[]' > "$GHS/issues.json"
HOME="$TMP4" O_DB="$TMP4/o.db" O_PORT="$PORT4" O_NO_OPEN=1 O_REVIEW=1 O_CLAUDE_BIN="$TMP4/claude-stub" \
  O_GH_BIN="$TMP4/gh-stub" GHS="$GHS" O_GH_POLL_S=2 O_CI_POLL_S=1 O_CI_SETTLE_S=0 \
  ./bin/swarmd >"$TMP4/daemon.log" 2>&1 &
DAEMON4_PID=$!
up4=""
for _i in $(seq 1 30); do
  code="$(ocurl -s -o /dev/null -w '%{http_code}' "$BASE4/api/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then up4="1"; break; fi
  sleep 0.5
done
[ -n "$up4" ] || { cat "$TMP4/daemon.log" || true; fail "review daemon never came up"; }
SCRATCHV="$TMP4/projv"
mkdir -p "$SCRATCHV"
git -C "$SCRATCHV" init -q -b main
git -C "$SCRATCHV" config user.email "o@example.com"
git -C "$SCRATCHV" config user.name "O Test"
cp "$SCRATCH/verify.sh" "$SCRATCHV/verify.sh"
echo "review project" > "$SCRATCHV/README.md"
git -C "$SCRATCHV" add -A
git -C "$SCRATCHV" commit -q -m "seed review project"
resp="$(ocurl -s -X POST "$BASE4/api/companies" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Review Co\",\"issue_prefix\":\"REV\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCHV\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}")"
CIDV="$(jget "$resp" 'd["id"]')"
ocurl -s -X POST "$BASE4/api/companies/$CIDV/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Revsim","runtime":"sim"}' >/dev/null
IID_APP="$(jget "$(ocurl -s -X POST "$BASE4/api/companies/$CIDV/issues" -H 'Content-Type: application/json' -d '{"title":"[sim:good] reviewer approves"}')" 'd["id"]')"
IID_REJ="$(jget "$(ocurl -s -X POST "$BASE4/api/companies/$CIDV/issues" -H 'Content-Type: application/json' -d '{"title":"[sim:good] [review:reject] reviewer rejects"}')" 'd["id"]')"
wait_status_at "$BASE4" "$IID_APP" "Done" 90 || { cat "$TMP4/daemon.log"; fail "review: approved change never Done"; }
git -C "$SCRATCHV" log --oneline main | grep "o/$IID_APP" >/dev/null || fail "review: approved change not merged"
wait_status_at "$BASE4" "$IID_REJ" "Failed" 150 || { cat "$TMP4/daemon.log"; fail "review: rejected change never Failed"; }
vs="$(sqlite3 "$TMP4/o.db" "SELECT verify_state FROM run WHERE issue_id='$IID_REJ' ORDER BY started_at DESC LIMIT 1")"
[ "$vs" = "red_review" ] || fail "review: expected red_review, got '$vs'"
sqlite3 "$TMP4/o.db" "SELECT verify_output FROM run WHERE issue_id='$IID_REJ' ORDER BY started_at DESC LIMIT 1" | grep -q "stub reviewer says" \
  || fail "review: rejection reason not recorded for the retry prompt"
git -C "$SCRATCHV" log --oneline main | grep -q "o/$IID_REJ" && fail "review: rejected change was merged"
# (count per target: the verify-final fix issue auto-filed for the rejected one
# is itself reviewed and may land review.pass rows of its own)
npass="$(sqlite3 "$TMP4/o.db" "SELECT COUNT(*) FROM activity WHERE verb='review.pass' AND target='$IID_APP'")"
nrej="$(sqlite3 "$TMP4/o.db" "SELECT COUNT(*) FROM activity WHERE verb='review.reject' AND target='$IID_REJ'")"
[ "$npass" = "1" ] && [ "$nrej" = "3" ] || fail "review: expected 1 review.pass + 3 review.reject, got $npass + $nrej"
pass "review gate: approve -> merged Done; reject x3 -> Failed red_review with reason, never merged"

# ---- GitHub in/out (same daemon: review gate + gh stub) --------
# ship=pr against a bare repo standing in for GitHub. GitHub issue #7 is
# imported once (even across many polls), shipped as a PR whose body says
# "Closes #7", and merged on green checks into the bare repo's main. A branch
# whose checks fail goes red_ci on every attempt -> Failed, never merged. A
# branch GitHub refuses to merge parks in "In Review".
git init -q --bare -b main "$GHS/remote.git"
SEEDGH="$TMP4/seedgh"
git clone -q "$GHS/remote.git" "$SEEDGH"
git -C "$SEEDGH" config user.email "o@example.com"; git -C "$SEEDGH" config user.name "O Test"
cp "$SCRATCH/verify.sh" "$SEEDGH/verify.sh"; echo "gh project" > "$SEEDGH/README.md"
git -C "$SEEDGH" add -A; git -C "$SEEDGH" commit -q -m "seed gh project"; git -C "$SEEDGH" push -q origin main
GHREPO="$TMP4/ghclone"
git clone -q "$GHS/remote.git" "$GHREPO"
git -C "$GHREPO" config user.email "o@example.com"; git -C "$GHREPO" config user.name "O Test"
resp="$(ocurl -s -w $'\n%{http_code}' -X POST "$BASE4/api/companies" -H 'Content-Type: application/json' \
  -d "{\"name\":\"GH Co\",\"issue_prefix\":\"GH\",\"budget_monthly_cents\":1000000,\"repo\":\"$GHREPO\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\",\"github_repo\":\"acme/widgets\",\"ship\":\"pr\"}")"
sc="$(printf '%s' "$resp" | tail -n1)"; body="$(printf '%s' "$resp" | sed '$d')"
[ "$sc" = "201" ] || { echo "$body"; fail "POST gh company expected 201, got $sc"; }
CIDG="$(jget "$body" 'd["id"]')"
[ "$(jget "$body" 'd["ship"]')" = "pr" ] && [ "$(jget "$body" 'd["github_repo"]')" = "acme/widgets" ] || fail "gh company fields not stored"
sc="$(ocurl -s -o /dev/null -w '%{http_code}' -X POST "$BASE4/api/companies/$CIDG" -H 'Content-Type: application/json' -d '{"ship":"yolo"}')"
[ "$sc" = "400" ] || fail "invalid ship value expected 400, got $sc"
# issues whose ids we need up front go in BEFORE the agent is hired
IID_CIF="$(jget "$(ocurl -s -X POST "$BASE4/api/companies/$CIDG/issues" -H 'Content-Type: application/json' -d '{"title":"[sim:good] ci goes red"}')" 'd["id"]')"
IID_BLK="$(jget "$(ocurl -s -X POST "$BASE4/api/companies/$CIDG/issues" -H 'Content-Type: application/json' -d '{"title":"[sim:good] needs a human"}')" 'd["id"]')"
echo "o/$IID_CIF" > "$GHS/fail_ci"
echo "o/$IID_BLK" > "$GHS/block_merge"
echo '[{"number":7,"title":"[sim:good] from github","body":"filed on GitHub"}]' > "$GHS/issues.json"
ocurl -s -X POST "$BASE4/api/companies/$CIDG/agents" \
  -H 'Content-Type: application/json' -d '{"name":"Ghsim","runtime":"sim"}' >/dev/null
IID_GH=""
for _i in $(seq 1 30); do
  IID_GH="$(sqlite3 "$TMP4/o.db" "SELECT id FROM issue WHERE company_id='$CIDG' AND fingerprint='gh:7'")"
  [ -n "$IID_GH" ] && break; sleep 1
done
[ -n "$IID_GH" ] || { tail -30 "$TMP4/daemon.log"; fail "github: issue #7 never imported"; }
[ "$(sqlite3 "$TMP4/o.db" "SELECT origin FROM issue WHERE id='$IID_GH'")" = "github" ] || fail "github: imported issue origin != github"
wait_status_at "$BASE4" "$IID_GH" "Done" 120 || { tail -40 "$TMP4/daemon.log"; fail "github: imported issue never Done"; }
git -C "$GHS/remote.git" log --oneline main | grep -q "o/$IID_GH" || { git -C "$GHS/remote.git" log --oneline main; fail "github: PR was not merged into the remote main"; }
grep -q "Closes #7" "$GHS/body_o_$IID_GH" || fail "github: PR body lacks 'Closes #7'"
[ -z "$(git -C "$GHREPO" branch --list "o/$IID_GH")" ] || fail "github: local branch not cleaned up after merge"
sleep 4  # more polls: #7 is still "open" on the stub and must not be re-imported
[ "$(sqlite3 "$TMP4/o.db" "SELECT COUNT(*) FROM issue WHERE company_id='$CIDG' AND fingerprint='gh:7'")" = "1" ] || fail "github: issue #7 imported more than once"
pass "github: #7 imported once, shipped as a PR (Closes #7), merged on green checks"
wait_status_at "$BASE4" "$IID_CIF" "Failed" 150 || { tail -40 "$TMP4/daemon.log"; fail "github: red-CI issue never Failed"; }
vs="$(sqlite3 "$TMP4/o.db" "SELECT verify_state FROM run WHERE issue_id='$IID_CIF' ORDER BY started_at DESC LIMIT 1")"
[ "$vs" = "red_ci" ] || fail "github: expected red_ci, got '$vs'"
sqlite3 "$TMP4/o.db" "SELECT verify_output FROM run WHERE issue_id='$IID_CIF' ORDER BY started_at DESC LIMIT 1" | grep -q "build" \
  || fail "github: failing check name not passed to the retry prompt"
[ ! -f "$GHS/merged_o_$IID_CIF" ] || fail "github: red-CI PR was merged"
pass "github: failing checks -> red_ci x3 -> Failed (check names in the retry tail), never merged"
wait_status_at "$BASE4" "$IID_BLK" "In Review" 90 || { tail -40 "$TMP4/daemon.log"; fail "github: merge-refused issue never parked In Review"; }
sleep 6
[ "$(sqlite3 "$TMP4/o.db" "SELECT status FROM issue WHERE id='$IID_BLK'")" = "In Review" ] || fail "github: In Review issue was re-dispatched"
pass "github: merge refused by branch policy -> parked In Review, not re-dispatched"

# ============================================================
# Agent sandbox — 5th daemon, O_SANDBOX=bwrap + O_API_TOKEN
# ============================================================
# A stub claude-code agent probes its own confinement and commits the results.
# Expected: the main checkout, the control-plane DB, .git/hooks and .git/config
# are not writable, ~/.o is hidden, and no process it can see carries
# O_API_TOKEN, yet its commit in the worktree still lands and merges. The
# daemon runs with O_API_TOKEN set, so the token guard is exercised for real.
# Skipped (with a note) where unprivileged bwrap can't run.
if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / --unshare-pid --proc /proc true 2>/dev/null; then
TMP5="$(mktemp -d)"
PORT5=$((5650 + RANDOM % 300))
BASE5="http://127.0.0.1:${PORT5}"
TOK="sbx-test-token"
SCRATCHS="$TMP5/projs"
mkdir -p "$SCRATCHS" "$TMP5/.o"
git -C "$SCRATCHS" init -q -b main
git -C "$SCRATCHS" config user.email "o@example.com"; git -C "$SCRATCHS" config user.name "O Test"
cp "$SCRATCH/verify.sh" "$SCRATCHS/verify.sh"; echo "sandbox project" > "$SCRATCHS/README.md"
git -C "$SCRATCHS" add -A; git -C "$SCRATCHS" commit -q -m "seed sandbox project"
cat > "$TMP5/agent-stub" <<'STUB'
#!/bin/sh
cat >/dev/null
p=""
if echo x >> "$SBX_REPO/README.md" 2>/dev/null; then p="$p repo:WRITABLE"; else p="$p repo:denied"; fi
if [ -e "$HOME/.o/o.db" ]; then p="$p db:VISIBLE"; else p="$p db:hidden"; fi
if echo x >> "$SBX_REPO/.git/hooks/post-merge" 2>/dev/null; then p="$p hooks:WRITABLE"; else p="$p hooks:denied"; fi
if git config core.fsmonitor "touch /tmp/pwned" 2>/dev/null; then p="$p config:WRITABLE"; else p="$p config:denied"; fi
n="$(cat /proc/*/environ 2>/dev/null | tr '\0' '\n' | grep -c '^O_API_TOKEN=')"
p="$p token_procs:$n"
echo "$p" > probes.txt
git add probes.txt && git commit -q -m "sandbox probes"
printf '%s\n' '{"type":"result","total_cost_usd":0.01,"session_id":"sbx-1"}'
STUB
chmod +x "$TMP5/agent-stub"
HOME="$TMP5" O_DB="$TMP5/.o/o.db" O_PORT="$PORT5" O_NO_OPEN=1 O_SANDBOX=bwrap O_API_TOKEN="$TOK" \
  O_CLAUDE_BIN="$TMP5/agent-stub" SBX_REPO="$SCRATCHS" ./bin/swarmd >"$TMP5/daemon.log" 2>&1 &
DAEMON5_PID=$!
up5=""
for _i in $(seq 1 30); do
  code="$(ocurl -s -o /dev/null -w '%{http_code}' "$BASE5/api/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then up5="1"; break; fi
  sleep 0.5
done
[ -n "$up5" ] || { cat "$TMP5/daemon.log" || true; fail "sandbox daemon never came up"; }
CO_JSON="{\"name\":\"Sandbox Co\",\"issue_prefix\":\"SBX\",\"budget_monthly_cents\":1000000,\"repo\":\"$SCRATCHS\",\"verify_cmd\":\"sh verify.sh\",\"protected_paths\":\"protected/\"}"
sc="$(ocurl -s -o /dev/null -w '%{http_code}' -X POST "$BASE5/api/companies" -H 'Content-Type: application/json' -d "$CO_JSON")"
[ "$sc" = "401" ] || fail "token: company create without bearer expected 401, got $sc"
CIDS="$(jget "$(ocurl -s -X POST "$BASE5/api/companies" -H 'Content-Type: application/json' -H "Authorization: Bearer $TOK" -d "$CO_JSON")" 'd["id"]')"
[ -n "$CIDS" ] || fail "token: company create with bearer failed"
sc="$(ocurl -s -o /dev/null -w '%{http_code}' -X POST "$BASE5/api/companies/$CIDS" -H 'Content-Type: application/json' -d '{"verify_cmd":"true"}')"
[ "$sc" = "401" ] || fail "token: verify_cmd rewrite without bearer expected 401, got $sc"
ocurl -s -X POST "$BASE5/api/companies/$CIDS/agents" -H 'Content-Type: application/json' -H "Authorization: Bearer $TOK" \
  -d '{"name":"Boxed","runtime":"claude-code"}' >/dev/null
IID_SBX="$(jget "$(ocurl -s -X POST "$BASE5/api/companies/$CIDS/issues" -H 'Content-Type: application/json' -d '{"title":"probe the sandbox"}')" 'd["id"]')"
[ -n "$IID_SBX" ] || fail "token: issue filing must stay open without a bearer"
pass "token: 401 on company writes without bearer (incl. verify_cmd rewrite), issue filing stays open"
wait_status_at "$BASE5" "$IID_SBX" "Done" 90 || { tail -30 "$TMP5/daemon.log"; fail "sandbox: boxed agent's issue never Done"; }
probes="$(git -C "$SCRATCHS" show main:probes.txt)"
[ "$probes" = " repo:denied db:hidden hooks:denied config:denied token_procs:0" ] \
  || fail "sandbox: unexpected probe results: '$probes'"
[ "$(cat "$SCRATCHS/README.md")" = "sandbox project" ] || fail "sandbox: main checkout was modified"
pass "sandbox: repo/hooks/config not writable, ~/.o hidden, token not visible in /proc; worktree commit merged"
else
  echo "SKIP: agent sandbox stage (unprivileged bwrap unavailable here)"
fi

# ============================================================
# Held-out invariant suite — the frozen core (tests/heldout/core.sh)
# ============================================================
# Run last. The full pipeline above has already exercised every worker;
# the held-out suite re-asserts the minimal INVARIANTS a self-modifying
# agent may never break, on its OWN throwaway daemon (temp DB + random
# port in a non-overlapping range). Kept lean so this stays sane.
echo
echo "=== held-out invariant suite (tests/heldout/core.sh) ==="
if ./tests/heldout/core.sh; then
  pass "held-out invariant suite green"
else
  fail "held-out invariant suite FAILED"
fi

echo
echo "ALL GREEN"
