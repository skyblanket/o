# ============================================================
# O v4 — orchestrator.sw  (the Symphony-style tick loop)
# ============================================================
#
# A single sw process is the sole authority for scheduling
# state — all mutations flow through it, so two ticks can never
# double-dispatch the same issue. A separate `ticker` process
# pokes it every tick_interval(); on each tick it:
#
#   1. reconcile — kill + retry any run past the stall timeout
#   2. fetch     — candidate issues (non-terminal, unclaimed)
#   3. dispatch  — assign an agent + spawn a worker, up to a cap
#
# P2: workers run REAL agent runtimes selected by the assigned
# agent's `runtime` field:
#   claude-code  — headless `claude -p` in a per-issue workspace
#   native       — single-shot LLM call over HTTP
#   sim          — deterministic stub (no spend; pipeline tests)
#
# In-memory scheduling state (Symphony model — reconstructible
# from the DB on restart):
#   running : issue_id -> %{run_id, worker_pid, started_at, attempt}
#   retry   : issue_id -> %{attempt, due_at}

module Orchestrator

import Store

export [start]

# ---- tunables ------------------------------------------------
fun max_concurrent() { 3 }        # PRD: configurable, default 10
fun tick_interval()  { 5000 }     # PRD: 30000
fun stall_timeout()  { 600000 }   # 10 min — real agent runs are slow
fun backoff_base()   { 2000 }     # PRD: 10000
fun max_backoff()    { 60000 }    # PRD: 300000
fun claude_bin()     { "/Users/sky/.local/bin/claude" }

# ---- small math helpers --------------------------------------
fun pow2(k) {
    if (k <= 0) { 1 } else { 2 * pow2(k - 1) }
}

fun min2(a, b) {
    if (a < b) { a } else { b }
}

fun backoff_ms(attempt) {
    min2(backoff_base() * pow2(attempt - 1), max_backoff())
}

fun default_body(v) {
    if (v == nil) { "" } else { v }
}

fun build_prompt(title, body) {
    "You are an autonomous agent in a fresh working directory. Complete the task below, creating whatever files are needed. Be concise.\n\nTask: " ++ title ++ "\n\n" ++ body
}

# ---- startup -------------------------------------------------
# Opens its own DB connection (separate from the HTTP loop's) so
# the two processes never share a sqlite handle across schedulers.
fun start(dbpath) {
    db = db_open(dbpath)
    _bt = db_exec(db, "PRAGMA busy_timeout=5000")
    orch = spawn(tick_loop(db, 0, %{}, %{}))
    register('orchestrator', orch)
    _ticker = spawn(ticker_loop(orch, tick_interval()))
    interval = tick_interval()
    cap = max_concurrent()
    print(f"  orchestrator  started (tick {interval}ms, max {cap} concurrent)")
    orch
}

fun ticker_loop(orch, interval) {
    sleep(interval)
    send(orch, 'tick')
    ticker_loop(orch, interval)
}

# ---- the orchestrator process: single authority --------------
fun tick_loop(db, tick_n, running, retry) {
    receive {
        'tick' ->
            r = do_tick(db, tick_n, running, retry)
            nr = map_get(r, "running")
            nq = map_get(r, "retry")
            rc = map_size(nr)
            qc = map_size(nq)
            print(f"[orch] tick {tick_n}  running={rc}  retry={qc}")
            tick_loop(db, tick_n + 1, nr, nq)
        {'run_done', run_id, issue_id, outcome} ->
            r = handle_done(db, running, retry, run_id, issue_id, outcome)
            tick_loop(db, tick_n, map_get(r, "running"), map_get(r, "retry"))
        {'snapshot', from} ->
            send(from, {'snapshot_reply', %{tick: tick_n, running: map_size(running), retrying: map_size(retry), tick_interval_ms: tick_interval(), max_concurrent: max_concurrent()}})
            tick_loop(db, tick_n, running, retry)
    }
}

# ---- one tick: reconcile, fetch, dispatch --------------------
fun do_tick(db, tick_n, running, retry) {
    now = timestamp()
    swept = sweep_stalls(db, map_keys(running), running, retry, now)
    sr = map_get(swept, "running")
    sq = map_get(swept, "retry")
    cands = Store.candidate_issues(db)
    slots = max_concurrent() - map_size(sr)
    dispatch_batch(db, cands, slots, sr, sq, now)
}

# Walk running entries; kill + retry any past the stall timeout.
fun sweep_stalls(db, ids, running, retry, now) {
    if (length(ids) == 0) {
        %{running: running, retry: retry}
    } else {
        iid = hd(ids)
        info = map_get(running, iid)
        age = now - map_get(info, "started_at")
        if (age > stall_timeout()) {
            _k = exit_proc(map_get(info, "worker_pid"), 'stalled')
            _m = Store.run_mark(db, map_get(info, "run_id"), "Stalled")
            _a = Store.log_activity(db, "", "orchestrator", "run.stalled", iid)
            running2 = map_remove(running, iid)
            retry2 = schedule_retry(retry, iid, map_get(info, "attempt"), now)
            sweep_stalls(db, tl(ids), running2, retry2, now)
        } else {
            sweep_stalls(db, tl(ids), running, retry, now)
        }
    }
}

# Dispatch up to `slots` eligible candidates.
fun dispatch_batch(db, cands, slots, running, retry, now) {
    if (slots <= 0) {
        %{running: running, retry: retry}
    } else {
        if (length(cands) == 0) {
            %{running: running, retry: retry}
        } else {
            issue = hd(cands)
            iid = map_get(issue, "id")
            if (map_has_key(running, iid) == 'true') {
                dispatch_batch(db, tl(cands), slots, running, retry, now)
            } else {
                if (is_cooling(retry, iid, now) == 'true') {
                    dispatch_batch(db, tl(cands), slots, running, retry, now)
                } else {
                    attempt = attempt_for(retry, iid)
                    running2 = dispatch_one(db, issue, iid, attempt, running, now)
                    retry2 = map_remove(retry, iid)
                    dispatch_batch(db, tl(cands), slots - 1, running2, retry2, now)
                }
            }
        }
    }
}

# Assign an agent, open a workspace, persist a run, spawn a worker.
# Skips the issue (running unchanged) if the company has no agents.
fun dispatch_one(db, issue, iid, attempt, running, now) {
    company_id = map_get(issue, "company_id")
    agent = Store.agent_first_active(db, company_id)
    if (agent == nil) {
        running
    } else {
        agent_id = map_get(agent, "id")
        runtime = map_get(agent, "runtime")
        home = getenv("HOME")
        workspace = f"{home}/.o/workspaces/{iid}"
        run_id = Store.run_create(db, iid, agent_id, attempt, "Running", workspace)
        _s = Store.issue_set_status(db, iid, "In Progress")
        _as = Store.issue_assign(db, iid, agent_id)
        _a = Store.log_activity(db, company_id, "orchestrator", "run.dispatch", iid)
        ident = map_get(issue, "identifier")
        print(f"[orch] dispatch {ident} via {runtime} (attempt {attempt})")
        prompt = build_prompt(map_get(issue, "title"), default_body(map_get(issue, "body")))
        sim_outcome = if (runtime == "sim") { decide_outcome(issue, attempt) } else { 'none' }
        wpid = spawn(run_worker(self(), run_id, iid, runtime, prompt, workspace, sim_outcome))
        map_put(running, iid, %{run_id: run_id, worker_pid: wpid, started_at: now, attempt: attempt})
    }
}

# ---- workers: real agent runtimes ----------------------------

fun run_worker(orch, run_id, issue_id, runtime, prompt, workspace, sim_outcome) {
    _mk = shell(f"mkdir -p {workspace}")
    if (runtime == "sim") {
        run_sim(orch, run_id, issue_id, sim_outcome)
    } else {
        if (runtime == "native") {
            run_native(orch, run_id, issue_id, prompt, workspace)
        } else {
            run_claude_code(orch, run_id, issue_id, prompt, workspace)
        }
    }
}

# claude-code runtime — a real headless `claude -p` run in the
# per-issue workspace. Exit 0 = succeeded; anything else = retry.
fun run_claude_code(orch, run_id, issue_id, prompt, workspace) {
    _w = file_write(f"{workspace}/PROMPT.txt", prompt)
    bin = claude_bin()
    cmd = f"cd {workspace} && cat PROMPT.txt | {bin} -p --dangerously-skip-permissions --output-format json > result.json 2> err.log"
    result = shell(cmd)
    code = elem(result, 0)
    if (code == 0) {
        send(orch, {'run_done', run_id, issue_id, 'succeeded'})
    } else {
        send(orch, {'run_done', run_id, issue_id, 'crashed'})
    }
}

# native runtime — single-shot LLM call. Needs O_LLM_URL/O_LLM_KEY.
fun run_native(orch, run_id, issue_id, prompt, workspace) {
    url = getenv("O_LLM_URL")
    if (url == nil) {
        send(orch, {'run_done', run_id, issue_id, 'crashed'})
    } else {
        key = getenv("O_LLM_KEY")
        reqbody = json_encode(%{messages: [%{role: "user", content: prompt}]})
        headers = ["Content-Type: application/json", f"Authorization: Bearer {key}"]
        resp = http_post(url, headers, reqbody)
        _save = file_write(f"{workspace}/result.json", resp)
        send(orch, {'run_done', run_id, issue_id, 'succeeded'})
    }
}

# sim runtime — deterministic stub, no spend. Used to exercise the
# scheduling pipeline (dispatch, retry, concurrency) without agents.
fun run_sim(orch, run_id, issue_id, outcome) {
    sleep(1000)
    send(orch, {'run_done', run_id, issue_id, outcome})
}

# attempt 1 of an even-sort_order issue crashes (then retries clean);
# everything else succeeds.
fun decide_outcome(issue, attempt) {
    if (attempt >= 2) {
        'succeeded'
    } else {
        if (map_get(issue, "sort_order") % 2 == 0) { 'crashed' } else { 'succeeded' }
    }
}

# ---- run completion ------------------------------------------
fun handle_done(db, running, retry, run_id, issue_id, outcome) {
    info = map_get(running, issue_id)
    if (info == nil) {
        %{running: running, retry: retry}
    } else {
        now = timestamp()
        if (outcome == 'succeeded') {
            _m = Store.run_mark(db, run_id, "Succeeded")
            _s = Store.issue_set_status(db, issue_id, "Done")
            _a = Store.log_activity(db, "", "orchestrator", "run.succeeded", issue_id)
            %{running: map_remove(running, issue_id), retry: map_remove(retry, issue_id)}
        } else {
            _m = Store.run_mark(db, run_id, "Failed")
            _a = Store.log_activity(db, "", "orchestrator", "run.failed", issue_id)
            retry2 = schedule_retry(retry, issue_id, map_get(info, "attempt"), now)
            %{running: map_remove(running, issue_id), retry: retry2}
        }
    }
}

# ---- retry bookkeeping ---------------------------------------
fun schedule_retry(retry, iid, attempt, now) {
    due = now + backoff_ms(attempt)
    map_put(retry, iid, %{attempt: attempt + 1, due_at: due})
}

fun is_cooling(retry, iid, now) {
    if (map_has_key(retry, iid) == 'true') {
        entry = map_get(retry, iid)
        if (map_get(entry, "due_at") > now) { 'true' } else { 'false' }
    } else {
        'false'
    }
}

fun attempt_for(retry, iid) {
    if (map_has_key(retry, iid) == 'true') {
        map_get(map_get(retry, iid), "attempt")
    } else {
        1
    }
}
