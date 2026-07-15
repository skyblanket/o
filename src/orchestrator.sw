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

export [start, chat_worker]

# ---- tunables ------------------------------------------------
fun max_concurrent() { 3 }        # PRD: configurable, default 10
fun tick_interval()  { 5000 }     # PRD: 30000
fun stall_timeout()  { 600000 }   # 10 min — real agent runs are slow
fun backoff_base()   { 2000 }     # PRD: 10000
fun max_backoff()    { 60000 }    # PRD: 300000
fun max_attempts()   { 3 }        # after this many failed runs, the issue is marked Failed

# ---- runtime binary discovery --------------------------------
# No absolute paths baked in: an explicit env override wins, then
# `command -v` on PATH, then a conventional home-relative fallback.
# Keeps the daemon portable across machines and CI.
fun which_bin(cmd) {
    r = shell(f"command -v {cmd}")
    out = string_trim(elem(r, 1))
    if (elem(r, 0) == 0) {
        if (string_length(out) > 0) { out } else { "" }
    } else {
        ""
    }
}

fun claude_bin() {
    e = getenv("O_CLAUDE_BIN")
    if (e == nil) {
        found = which_bin("claude")
        if (string_length(found) > 0) {
            found
        } else {
            home = getenv("HOME")
            f"{home}/.local/bin/claude"
        }
    } else {
        e
    }
}

fun swarm_bin() {
    e = getenv("O_SWARM_BIN")
    if (e == nil) {
        found = which_bin("swarm-code")
        if (string_length(found) > 0) {
            found
        } else {
            found2 = which_bin("swarm")
            if (string_length(found2) > 0) {
                found2
            } else {
                home = getenv("HOME")
                f"{home}/swarm-code/bin/swarm-code"
            }
        }
    } else {
        e
    }
}

# Per-run cost ceiling for claude-code: --max-turns caps how many
# agent turns a single issue run may take. O_MAX_TURNS overrides.
fun max_turns() {
    t = getenv("O_MAX_TURNS")
    if (t == nil) { "50" } else { t }
}

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

# ---- one tick: rollover, reconcile, fetch, dispatch ----------
fun do_tick(db, tick_n, running, retry) {
    now = timestamp()
    _rb = maybe_rollover(db, now)
    swept = sweep_stalls(db, map_keys(running), running, retry, now)
    sr = map_get(swept, "running")
    sq = map_get(swept, "retry")
    cands = Store.candidate_issues(db)
    slots = dispatch_slots(db, map_size(sr))
    dispatch_batch(db, cands, slots, sr, sq, now)
}

# Daily rollover: reset per-day counters and lift daily-budget pauses.
# Store.rollover_day returns the ids of companies it rolled; log one
# budget.reset per company (actor budget-guard).
fun maybe_rollover(db, now) {
    rolled = Store.rollover_day(db, now)
    log_rolled(db, rolled)
}

fun log_rolled(db, ids) {
    if (length(ids) == 0) {
        ""
    } else {
        cid = hd(ids)
        _a = Store.log_activity(db, cid, "budget-guard", "budget.reset", cid)
        log_rolled(db, tl(ids))
    }
}

# Available dispatch slots this tick. Normally max_concurrent minus
# what is already running, but if the global daily spend cap
# (O_GLOBAL_DAILY_CENTS) is set and already met, dispatch zero this
# tick — stalls are still swept regardless.
fun dispatch_slots(db, running_size) {
    base = max_concurrent() - running_size
    cap = getenv("O_GLOBAL_DAILY_CENTS")
    if (cap == nil) {
        base
    } else {
        limit = to_int(cap)
        if (limit == nil) {
            base
        } else {
            if (Store.global_spent_today(db) >= limit) {
                _p = print(f"[orch] GLOBAL daily cap {limit}c reached — dispatching 0 slots this tick")
                0
            } else {
                base
            }
        }
    }
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
        if (runtime == "swarm-code") {
            run_swarm_code(orch, run_id, issue_id, prompt, workspace, repo)
        } else {
            run_claude_code(orch, run_id, issue_id, prompt, workspace, repo, session_id)
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
    # stream-json: one JSON event per turn so the UI can watch the
    # agent work live. The final {type:"result"} event carries cost
    # and session — parse_stream_* find it after the run.
    turns = max_turns()
    cmd = f"cd {workspace} && cat PROMPT.txt | {bin} -p{resume} --max-turns {turns} --dangerously-skip-permissions --verbose --output-format stream-json > stream.jsonl 2> err.log"
    result = shell(cmd)
    code = elem(result, 0)
    cost = parse_stream_cost(f"{workspace}/stream.jsonl")
    new_session = parse_stream_session(f"{workspace}/stream.jsonl")
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

# ---- stream-json parsers ----------------------------------------
# Issue runs use --output-format stream-json (line-delimited events)
# so the UI can show live activity. The final {type:"result"} event
# carries cost/session/summary. These helpers walk the file after
# the run completes and pull what we need.

fun find_result_event(lines) {
    if (length(lines) == 0) {
        %{}
    } else {
        line = hd(lines)
        if (string_length(line) == 0) {
            find_result_event(tl(lines))
        } else {
            data = json_decode(line)
            if (data == nil) {
                find_result_event(tl(lines))
            } else {
                if (map_get(data, "type") == "result") { data }
                else { find_result_event(tl(lines)) }
            }
        }
    }
}

fun parse_stream_result(path) {
    if (file_exists(path) == 'true') {
        raw = file_read(path)
        if (string_length(raw) == 0) { %{} }
        else { find_result_event(string_split(raw, "\n")) }
    } else {
        %{}
    }
}

fun parse_stream_cost(path) {
    d = parse_stream_result(path)
    usd = map_get(d, "total_cost_usd")
    if (usd == nil) { 0 } else { usd * 100 }
}

fun parse_stream_session(path) {
    d = parse_stream_result(path)
    s = map_get(d, "session_id")
    if (s == nil) { "" } else { s }
}

# swarm-code runtime — the swarmrt-native coding agent. Driven through
# swarm-code's headless mode: the prompt is piped on stdin to
# `swarm-code -p --json`, which runs the agent to task-completion,
# emits a final {"status","summary"} line, and exits 0 / nonzero.
#
# swarm-code persists + auto-resumes its own per-cwd session journal,
# so an agent's context carries across the issues it works — the
# swarm-code-native equivalent of the claude-code session resume. No
# cost or session id flows back: swarm-code reports neither, and its
# continuity is the journal, not an id O has to thread.
fun run_swarm_code(orch, run_id, issue_id, prompt, workspace, repo) {
    if (string_length(repo) > 0) {
        prepare_worktree(repo, workspace, issue_id)
    } else {
        _mk = shell(f"mkdir -p {workspace}")
    }
    _w = file_write(f"{workspace}/PROMPT.txt", prompt)
    bin = swarm_bin()
    cmd = f"cd {workspace} && cat PROMPT.txt | SWARM_CODE_CWD={workspace} {bin} -p --json > result.json 2> err.log"
    result = shell(cmd)
    code = elem(result, 0)
    cost = swarm_flat_cents()
    if (code == 0) {
        send(orch, {'run_done', run_id, issue_id, 'succeeded', cost, ""})
    } else {
        send(orch, {'run_done', run_id, issue_id, 'crashed', cost, ""})
    }
}

# swarm-code reports neither cost nor tokens today, so a real run
# would otherwise be charged 0 and bypass the budget guard entirely.
# Charge a flat per-run estimate instead; O_SWARM_FLAT_CENTS overrides,
# default 25.
# TODO: replace with real token telemetry once swarm-code emits a
# final usage event (mirror the claude-code stream-json result parse).
fun swarm_flat_cents() {
    v = getenv("O_SWARM_FLAT_CENTS")
    if (v == nil) {
        25
    } else {
        n = to_int(v)
        if (n == nil) { 25 } else { n }
    }
}

# ============================================================
# Chat — operator <-> agent conversation
# ============================================================
#
# A chat turn runs ONE operator message against the agent's runtime,
# resuming the agent's persistent session — so the agent you chat
# with is the same one that works the issues: chat sees the issue
# history, issues see the chat. Spawned as its own process by the
# router so a slow LLM turn never blocks the HTTP request loop; the
# agent's reply lands in the `message` table and the dashboard's
# poll picks it up.
fun chat_worker(dbpath, agent_id, message) {
    db = db_open(dbpath)
    _bt = db_exec(db, "PRAGMA busy_timeout=5000")
    agent = Store.agent_row(db, agent_id)
    if (agent == nil) {
        ""
    } else {
        runtime = map_get(agent, "runtime")
        rawses = map_get(agent, "chat_session_id")
        session_id = if (rawses == nil) { "" } else { rawses }
        home = getenv("HOME")
        workspace = f"{home}/.o/chat/{agent_id}"
        _mk = shell(f"mkdir -p {workspace}")
        _w = file_write(f"{workspace}/CHAT.txt", message)
        outcome = chat_invoke(runtime, workspace, session_id)
        new_session = map_get(outcome, "session")
        if (string_length(new_session) > 0) {
            _ss = Store.agent_set_chat_session(db, agent_id, new_session)
        } else {
            ""
        }
        _m = Store.message_create(db, agent_id, "agent", map_get(outcome, "reply"))
        ""
    }
}

# Run one chat turn through the agent's runtime. Returns
# %{reply, session} — reply is the agent's text, session the
# (possibly new) session id to persist.
fun chat_invoke(runtime, workspace, session_id) {
    if (runtime == "swarm-code") {
        bin = swarm_bin()
        _r = shell(f"cd {workspace} && cat CHAT.txt | SWARM_CODE_CWD={workspace} {bin} -p --json > reply.json 2> err.log")
        %{reply: chat_reply_swarm(f"{workspace}/reply.json"), session: ""}
    } else {
        bin = claude_bin()
        resume = if (string_length(session_id) > 0) { f" --resume {session_id}" } else { "" }
        _r = shell(f"cd {workspace} && cat CHAT.txt | {bin} -p{resume} --dangerously-skip-permissions --output-format json > reply.json 2> err.log")
        reply = chat_reply_claude(f"{workspace}/reply.json")
        if (reply == "(no reply)") {
            # the stored session was stale / not found in this dir —
            # retry once with a fresh session so chat never dead-ends.
            _r2 = shell(f"cd {workspace} && cat CHAT.txt | {bin} -p --dangerously-skip-permissions --output-format json > reply.json 2> err.log")
            %{reply: chat_reply_claude(f"{workspace}/reply.json"), session: parse_session(f"{workspace}/reply.json")}
        } else {
            %{reply: reply, session: parse_session(f"{workspace}/reply.json")}
        }
    }
}

# claude-code --output-format json: the `result` field is the reply.
fun chat_reply_claude(path) {
    if (file_exists(path) == 'true') {
        raw = file_read(path)
        if (string_length(raw) == 0) {
            "(no reply)"
        } else {
            d = json_decode(raw)
            r = if (d == nil) { nil } else { map_get(d, "result") }
            if (r == nil) { "(no reply)" } else { to_string(r) }
        }
    } else {
        "(no reply)"
    }
}

# swarm-code -p --json streams the work, then a final {"summary"}
# line — take the last line, fall back to the raw text.
fun chat_reply_swarm(path) {
    if (file_exists(path) == 'true') {
        raw = string_trim(file_read(path))
        if (string_length(raw) == 0) {
            "(no reply)"
        } else {
            lines = string_split(raw, "\n")
            last = last_line(lines)
            d = json_decode(last)
            s = if (d == nil) { nil } else { map_get(d, "summary") }
            if (s == nil) { raw } else { to_string(s) }
        }
    } else {
        "(no reply)"
    }
}

fun last_line(lines) {
    if (length(lines) == 0) { "" }
    else { if (length(lines) == 1) { hd(lines) }
    else { last_line(tl(lines)) }}
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
            attempt = map_get(info, "attempt")
            _m = Store.run_finish(db, run_id, "Failed", cost)
            account_cost(db, company_id, cost)
            if (attempt >= max_attempts()) {
                # exhausted retries — mark the issue Failed (terminal), don't loop
                _s = Store.issue_set_status(db, issue_id, "Failed")
                _a = Store.log_activity(db, company_id, "orchestrator", "run.failed_final", issue_id)
                %{running: map_remove(running, issue_id), retry: map_remove(retry, issue_id)}
            } else {
                _a = Store.log_activity(db, company_id, "orchestrator", "run.failed", issue_id)
                retry2 = schedule_retry(retry, issue_id, attempt, now)
                %{running: map_remove(running, issue_id), retry: retry2}
            }
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
