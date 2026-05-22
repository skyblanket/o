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
fun swarm_bin()      { "/Users/sky/swarm-code/bin/swarm-code" }

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

fun build_prompt(title, body, repo) {
    if (string_length(repo) > 0) {
        "You are an autonomous engineer working in a git checkout of a real project. Make the code changes this task needs, then run `git add -A` and `git commit -m` with a clear message. Do NOT commit PROMPT.txt, result.json or err.log. Be focused and correct.\n\nTask: " ++ title ++ "\n\n" ++ body
    } else {
        "You are an autonomous agent in a fresh working directory. Complete the task below, creating whatever files are needed. Be concise.\n\nTask: " ++ title ++ "\n\n" ++ body
    }
}

# sim runtime reports a fixed fake cost so budget enforcement can be
# exercised without real spend. claude-code reports its true cost.
fun sim_cost() { 300 }

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
        {'run_done', run_id, issue_id, outcome, cost, session_id} ->
            r = handle_done(db, running, retry, run_id, issue_id, outcome, cost, session_id)
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
            _m = Store.run_finish(db, map_get(info, "run_id"), "Stalled", 0)
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
# Pick the agent for an issue: its manual assignee if set and valid,
# otherwise the company's first active agent.
fun pick_agent(db, company_id, assignee) {
    if (assignee == nil) {
        Store.agent_first_active(db, company_id)
    } else {
        if (string_length(assignee) == 0) {
            Store.agent_first_active(db, company_id)
        } else {
            a = Store.agent_row(db, assignee)
            if (a == nil) { Store.agent_first_active(db, company_id) } else { a }
        }
    }
}

fun dispatch_one(db, issue, iid, attempt, running, now) {
    company_id = map_get(issue, "company_id")
    agent = pick_agent(db, company_id, map_get(issue, "assignee_agent_id"))
    if (agent == nil) {
        running
    } else {
        agent_id = map_get(agent, "id")
        runtime = map_get(agent, "runtime")
        rawrepo = map_get(agent, "repo")
        repo = if (rawrepo == nil) { "" } else { rawrepo }
        # The agent's durable runtime session — empty on its first ever
        # run, then resumed on every issue after, so it accumulates context.
        rawses = map_get(agent, "session_id")
        session_id = if (rawses == nil) { "" } else { rawses }
        home = getenv("HOME")
        workspace = f"{home}/.o/workspaces/{iid}"
        run_id = Store.run_create(db, iid, agent_id, attempt, "Running", workspace)
        _s = Store.issue_set_status(db, iid, "In Progress")
        _as = Store.issue_assign(db, iid, agent_id)
        _a = Store.log_activity(db, company_id, "orchestrator", "run.dispatch", iid)
        ident = map_get(issue, "identifier")
        resumed = if (string_length(session_id) > 0) { "resume" } else { "fresh" }
        print(f"[orch] dispatch {ident} via {runtime} ({resumed} session, attempt {attempt})")
        prompt = build_prompt(map_get(issue, "title"), default_body(map_get(issue, "body")), repo)
        sim_outcome = if (runtime == "sim") { decide_outcome(issue, attempt) } else { 'none' }
        wpid = spawn(run_worker(self(), run_id, iid, runtime, prompt, workspace, repo, session_id, sim_outcome))
        map_put(running, iid, %{run_id: run_id, worker_pid: wpid, started_at: now, attempt: attempt, company_id: company_id, agent_id: agent_id})
    }
}

# ---- workers: real agent runtimes ----------------------------

fun run_worker(orch, run_id, issue_id, runtime, prompt, workspace, repo, session_id, sim_outcome) {
    if (runtime == "sim") {
        run_sim(orch, run_id, issue_id, sim_outcome)
    } else {
        if (runtime == "native") {
            _mk = shell(f"mkdir -p {workspace}")
            run_native(orch, run_id, issue_id, prompt, workspace)
        } else {
            if (runtime == "swarm-code") {
                run_swarm_code(orch, run_id, issue_id, prompt, workspace, repo)
            } else {
                run_claude_code(orch, run_id, issue_id, prompt, workspace, repo, session_id)
            }
        }
    }
}

# claude-code runtime — a real headless `claude -p` run in the
# per-issue workspace. Exit 0 = succeeded; anything else = retry.
# Real cost is parsed from result.json (total_cost_usd).
#
# Shape B — persistent agent: if the agent already has a session_id,
# the run is `claude -p --resume <id>`, so the agent's conversation
# CONTINUES across every issue it's handed. The (possibly new)
# session id is parsed back out and returned in run_done, where the
# orchestrator persists it onto the agent.
fun run_claude_code(orch, run_id, issue_id, prompt, workspace, repo, session_id) {
    if (string_length(repo) > 0) {
        prepare_worktree(repo, workspace, issue_id)
    } else {
        _mk = shell(f"mkdir -p {workspace}")
    }
    _w = file_write(f"{workspace}/PROMPT.txt", prompt)
    bin = claude_bin()
    resume = if (string_length(session_id) > 0) { f" --resume {session_id}" } else { "" }
    cmd = f"cd {workspace} && cat PROMPT.txt | {bin} -p{resume} --dangerously-skip-permissions --output-format json > result.json 2> err.log"
    result = shell(cmd)
    code = elem(result, 0)
    cost = parse_cost(f"{workspace}/result.json")
    new_session = parse_session(f"{workspace}/result.json")
    if (code == 0) {
        send(orch, {'run_done', run_id, issue_id, 'succeeded', cost, new_session})
    } else {
        send(orch, {'run_done', run_id, issue_id, 'crashed', cost, new_session})
    }
}

# Parse total_cost_usd from a claude-code result.json -> cents.
fun parse_cost(path) {
    if (file_exists(path) == 'true') {
        raw = file_read(path)
        if (string_length(raw) == 0) {
            0
        } else {
            usd = map_get(json_decode(raw), "total_cost_usd")
            if (usd == nil) { 0 } else { usd * 100 }
        }
    } else {
        0
    }
}

# Parse the session_id from a claude-code result.json. This is the
# durable thread the agent resumes on its next issue.
fun parse_session(path) {
    if (file_exists(path) == 'true') {
        raw = file_read(path)
        if (string_length(raw) == 0) {
            ""
        } else {
            sid = map_get(json_decode(raw), "session_id")
            if (sid == nil) { "" } else { sid }
        }
    } else {
        ""
    }
}

# swarm-code runtime — the swarmrt-native coding agent. The code path
# is wired and structured, but swarm-code is interactive-only today:
# piped a prompt it does the work, then sits at its REPL prompt and
# never exits — so O cannot drive it one-shot. It DOES already persist
# + auto-resume its own per-cwd session (its continuity is built in).
#
# The single missing piece is a headless mode — `swarm -p "<prompt>"`
# that runs the agent to task-completion and exits 0. Once swarm-code
# ships that, the body below becomes a one-line `shell(...)` swap and
# swarm-code is a first-class runtime. Until then this fails fast with
# a clear reason rather than hanging the orchestrator for minutes.
fun run_swarm_code(orch, run_id, issue_id, prompt, workspace, repo) {
    _mk = shell(f"mkdir -p {workspace}")
    _w = file_write(f"{workspace}/PROMPT.txt", prompt)
    _e = file_write(f"{workspace}/err.log", "swarm-code runtime not yet drivable: swarm-code is interactive-only and never exits after a task. It needs a headless `swarm -p` mode. Use the claude-code runtime until then.")
    send(orch, {'run_done', run_id, issue_id, 'crashed', 0, ""})
}

# Create an isolated git worktree of `repo` for this issue, on a fresh
# branch o/<issue_id>. Reused as-is if it already exists (e.g. retry),
# so concurrent issues never touch each other's checkout.
fun prepare_worktree(repo, workspace, issue_id) {
    if (file_exists(workspace) == 'true') {
        ""
    } else {
        branch = f"o/{issue_id}"
        _wt = shell(f"git -C {repo} worktree add {workspace} -b {branch}")
        ""
    }
}

# native runtime — single-shot LLM call. Needs O_LLM_URL/O_LLM_KEY.
fun run_native(orch, run_id, issue_id, prompt, workspace) {
    url = getenv("O_LLM_URL")
    if (url == nil) {
        send(orch, {'run_done', run_id, issue_id, 'crashed', 0, ""})
    } else {
        key = getenv("O_LLM_KEY")
        reqbody = json_encode(%{messages: [%{role: "user", content: prompt}]})
        headers = ["Content-Type: application/json", f"Authorization: Bearer {key}"]
        resp = http_post(url, headers, reqbody)
        _save = file_write(f"{workspace}/result.json", resp)
        send(orch, {'run_done', run_id, issue_id, 'succeeded', 0, ""})
    }
}

# sim runtime — deterministic stub, no real spend. Reports a fixed
# fake cost so the budget hard-stop can be exercised without agents.
fun run_sim(orch, run_id, issue_id, outcome) {
    sleep(1000)
    send(orch, {'run_done', run_id, issue_id, outcome, sim_cost(), ""})
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

# Persist the agent's runtime session id once a run reports one, so
# the next issue resumes the same conversation. Runs even on a failed
# attempt — a crashed run may still have opened a session worth keeping.
fun persist_session(db, info, session_id) {
    if (string_length(session_id) > 0) {
        _u = Store.agent_set_session(db, map_get(info, "agent_id"), session_id)
        ""
    } else {
        ""
    }
}

# ---- run completion ------------------------------------------
fun handle_done(db, running, retry, run_id, issue_id, outcome, cost, session_id) {
    info = map_get(running, issue_id)
    if (info == nil) {
        %{running: running, retry: retry}
    } else {
        now = timestamp()
        company_id = map_get(info, "company_id")
        _ps = persist_session(db, info, session_id)
        if (outcome == 'succeeded') {
            _m = Store.run_finish(db, run_id, "Succeeded", cost)
            _s = Store.issue_set_status(db, issue_id, "Done")
            account_cost(db, company_id, cost)
            _a = Store.log_activity(db, company_id, "orchestrator", "run.succeeded", issue_id)
            %{running: map_remove(running, issue_id), retry: map_remove(retry, issue_id)}
        } else {
            _m = Store.run_finish(db, run_id, "Failed", cost)
            account_cost(db, company_id, cost)
            _a = Store.log_activity(db, company_id, "orchestrator", "run.failed", issue_id)
            retry2 = schedule_retry(retry, issue_id, map_get(info, "attempt"), now)
            %{running: map_remove(running, issue_id), retry: retry2}
        }
    }
}

# The cost hook: accumulate run cost onto the company, then let the
# budget guard hard-stop the company if it has hit its cap.
fun account_cost(db, company_id, cost) {
    _s = Store.company_add_spend(db, company_id, cost)
    if (Store.enforce_budget(db, company_id) == 'paused') {
        _a = Store.log_activity(db, company_id, "budget-guard", "budget.exceeded", company_id)
        print(f"[orch] BUDGET  {company_id} hit its cap — company paused")
    } else {
        ""
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
