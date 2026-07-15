# ============================================================
# O v4 — store.sw  (data-access layer over the SQLite spine)
# ============================================================
#
# Every function is company-scoped and returns plain sw values
# (row maps / lists of row maps) so callers can json_encode them
# directly. No business logic here — just persistence, plus the
# budget check (enforce_budget) which is a pure DB operation.

module Store

export [next_id, companies, company_row, company_create, company_update,
        company_add_spend, enforce_budget, rollover_day, company_mark_green, global_spent_today,
        issues_for, issue_row, issue_create, issue_set_status, issue_assign, issue_update,
        log_activity, activity_recent, candidate_issues,
        run_create, run_finish, runs_all, run_row,
        agents_for, agent_row, agent_first_active, agent_create,
        agent_set_session, agent_set_chat_session,
        message_create, messages_for,
        approval_create, approvals_pending, approval_row, approval_set]

# Ask the registered `idgen` process for a fresh unique id.
fun next_id(prefix) {
    send(whereis('idgen'), {'gen', self(), prefix})
    receive {
        {'id', x} -> x
    }
}

# ---- companies ------------------------------------------------

fun companies(db) {
    db_query(db, "SELECT id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at, repo, verify_cmd, protected_paths, budget_daily_cents, spent_today_cents, budget_day, pause_reason, greens_today, no_signal_days, last_reflect_day FROM company ORDER BY created_at DESC", [])
}

fun company_row(db, id) {
    rows = db_query(db, "SELECT id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at, repo, verify_cmd, protected_paths, budget_daily_cents, spent_today_cents, budget_day, pause_reason, greens_today, no_signal_days, last_reflect_day FROM company WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun company_create(db, name, mission, prefix, budget, repo, verify_cmd, protected_paths, budget_daily) {
    id = next_id("co")
    now = timestamp()
    _ins = db_query(db, "INSERT INTO company (id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at, repo, verify_cmd, protected_paths, budget_daily_cents) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [id, name, mission, prefix, "active", budget, 0, 0, now, now, repo, verify_cmd, protected_paths, budget_daily])
    id
}

fun company_update(db, id, budget, status, repo, verify_cmd, protected_paths, budget_daily) {
    _u = db_query(db, "UPDATE company SET budget_monthly_cents = ?, status = ?, repo = ?, verify_cmd = ?, protected_paths = ?, budget_daily_cents = ?, updated_at = ? WHERE id = ?", [budget, status, repo, verify_cmd, protected_paths, budget_daily, timestamp(), id])
    id
}

fun company_add_spend(db, id, cents) {
    _u = db_query(db, "UPDATE company SET spent_cents = spent_cents + CAST(ROUND(?) AS INTEGER), spent_today_cents = spent_today_cents + CAST(ROUND(?) AS INTEGER), updated_at = ? WHERE id = ?", [cents, cents, timestamp(), id])
    id
}

# The budget hard-stop: if a company has reached a budget cap, flip it
# to 'paused' and record which cap tripped in pause_reason. The DAILY
# cap is checked first (tighter, resets each rollover), then the monthly
# cap. Returns 'paused' if this call paused it, else 'ok' — the caller
# (orchestrator account_cost) depends on that atom contract.
fun enforce_budget(db, company_id) {
    rows = db_query(db, "SELECT budget_monthly_cents, spent_cents, budget_daily_cents, spent_today_cents, status FROM company WHERE id = ?", [company_id])
    if (length(rows) == 0) {
        'ok'
    } else {
        c = hd(rows)
        budget = map_get(c, "budget_monthly_cents")
        spent = map_get(c, "spent_cents")
        budget_daily = map_get(c, "budget_daily_cents")
        spent_today = map_get(c, "spent_today_cents")
        status = map_get(c, "status")
        if (status != "active") {
            'ok'
        } else {
            if (budget_daily > 0 && spent_today >= budget_daily) {
                _u = db_query(db, "UPDATE company SET status = 'paused', pause_reason = 'budget-daily', updated_at = ? WHERE id = ?", [timestamp(), company_id])
                'paused'
            } else {
                if (budget > 0 && spent >= budget) {
                    _u = db_query(db, "UPDATE company SET status = 'paused', pause_reason = 'budget-monthly', updated_at = ? WHERE id = ?", [timestamp(), company_id])
                    'paused'
                } else {
                    'ok'
                }
            }
        }
    }
}

# Daily rollover. `today` is the epoch-day computed IN SQL (int/int in
# SQLite) so no sw float→int is needed. For every company whose stored
# budget_day is not today, reset the daily spend + green counters, stamp
# the new day, and un-pause any company that was stopped on the DAILY
# cap (a monthly hard-stop survives the rollover). Returns the list of
# rolled company ids so the caller can log a budget.reset per company.
#
# Phase-4 hook: the no-signal evaluation (greens_today == 0 → bump
# no_signal_days, maybe trigger reflection) lands here, reading the
# about-to-be-reset counters BEFORE they are zeroed.
fun rollover_day(db, now_ms) {
    rows = db_query(db, "SELECT id FROM company WHERE budget_day != (? / 86400000)", [now_ms])
    ids = map_ids(rows)
    _r = db_query(db, "UPDATE company SET spent_today_cents = 0, greens_today = 0, budget_day = (? / 86400000), updated_at = ? WHERE budget_day != (? / 86400000)", [now_ms, timestamp(), now_ms])
    _u = db_query(db, "UPDATE company SET status = 'active', pause_reason = '' WHERE pause_reason = 'budget-daily'", [])
    ids
}

# Pull the "id" column out of a list of row maps into a plain list.
fun map_ids(rows) {
    if (length(rows) == 0) {
        []
    } else {
        [map_get(hd(rows), "id")] ++ map_ids(tl(rows))
    }
}

# A verified-green run bumps the company's daily green counter — the
# positive signal the Phase-4 no-signal evaluation reads at rollover.
fun company_mark_green(db, id) {
    _u = db_query(db, "UPDATE company SET greens_today = greens_today + 1, updated_at = ? WHERE id = ?", [timestamp(), id])
    id
}

# Total daily spend across all companies — the input to the global
# daily cap the orchestrator enforces before dispatching.
fun global_spent_today(db) {
    rows = db_query(db, "SELECT COALESCE(SUM(spent_today_cents), 0) AS total FROM company", [])
    if (length(rows) == 0) { 0 } else { map_get(hd(rows), "total") }
}

# ---- issues ---------------------------------------------------

fun issues_for(db, company_id) {
    db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, assignee_agent_id, goal_id, sort_order, created_at, updated_at, origin, fingerprint FROM issue WHERE company_id = ? ORDER BY sort_order ASC", [company_id])
}

fun issue_row(db, id) {
    rows = db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, assignee_agent_id, goal_id, sort_order, created_at, updated_at, origin, fingerprint FROM issue WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

# Returns the new issue id, or nil if the company does not exist.
fun issue_create(db, company_id, title, body, priority) {
    crow = company_row(db, company_id)
    if (crow == nil) {
        nil
    } else {
        prefix = map_get(crow, "issue_prefix")
        n = map_get(crow, "issue_counter") + 1
        identifier = f"{prefix}-{n}"
        id = next_id("iss")
        now = timestamp()
        _upd = db_query(db, "UPDATE company SET issue_counter = ?, updated_at = ? WHERE id = ?", [n, now, company_id])
        _ins = db_query(db, "INSERT INTO issue (id, company_id, identifier, title, body, status, priority, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [id, company_id, identifier, title, body, "Backlog", priority, now, now, now])
        id
    }
}

fun issue_set_status(db, id, status) {
    _u = db_query(db, "UPDATE issue SET status = ?, updated_at = ? WHERE id = ?", [status, timestamp(), id])
    id
}

fun issue_assign(db, id, agent_id) {
    _u = db_query(db, "UPDATE issue SET assignee_agent_id = ? WHERE id = ?", [agent_id, id])
    id
}

# Non-terminal issues belonging to ACTIVE companies (a paused company
# — budget hard-stop — yields no candidates). Priority, then age.
fun candidate_issues(db) {
    db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, assignee_agent_id, sort_order, origin, fingerprint FROM issue WHERE status NOT IN ('Done', 'Canceled', 'Failed') AND company_id IN (SELECT id FROM company WHERE status = 'active') ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, created_at ASC", [])
}

# Partial update of the operator-editable issue fields.
fun issue_update(db, id, status, priority, assignee) {
    _u = db_query(db, "UPDATE issue SET status = ?, priority = ?, assignee_agent_id = ?, updated_at = ? WHERE id = ?", [status, priority, assignee, timestamp(), id])
    id
}

# ---- agents ---------------------------------------------------

fun agents_for(db, company_id) {
    db_query(db, "SELECT id, company_id, name, role, department, model, runtime, repo, session_id, status, created_at FROM agent WHERE company_id = ? ORDER BY created_at ASC", [company_id])
}

fun agent_row(db, id) {
    rows = db_query(db, "SELECT id, company_id, name, role, department, model, runtime, repo, session_id, chat_session_id, status, created_at FROM agent WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun agent_first_active(db, company_id) {
    rows = db_query(db, "SELECT id, company_id, name, role, runtime, repo, session_id, status FROM agent WHERE company_id = ? AND status = 'active' ORDER BY created_at ASC LIMIT 1", [company_id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun agent_create(db, company_id, name, role, runtime, model, repo) {
    id = next_id("ag")
    _ins = db_query(db, "INSERT INTO agent (id, company_id, name, role, runtime, model, repo, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", [id, company_id, name, role, runtime, model, repo, "active", timestamp()])
    id
}

# Persist the agent's runtime session id — the durable conversation
# thread it resumes on every issue. Written after each run completes,
# so the agent accumulates context across all the work it does.
fun agent_set_session(db, agent_id, session_id) {
    _u = db_query(db, "UPDATE agent SET session_id = ? WHERE id = ?", [session_id, agent_id])
    agent_id
}

# The chat conversation's own session — separate from issue runs.
fun agent_set_chat_session(db, agent_id, session_id) {
    _u = db_query(db, "UPDATE agent SET chat_session_id = ? WHERE id = ?", [session_id, agent_id])
    agent_id
}

# ---- chat messages -------------------------------------------
# Operator <-> agent conversation. role is 'operator' or 'agent'.

fun message_create(db, agent_id, role, content) {
    id = next_id("msg")
    _i = db_query(db, "INSERT INTO message (id, agent_id, role, content, created_at) VALUES (?, ?, ?, ?, ?)", [id, agent_id, role, content, timestamp()])
    id
}

fun messages_for(db, agent_id) {
    db_query(db, "SELECT id, agent_id, role, content, created_at FROM message WHERE agent_id = ? ORDER BY created_at ASC", [agent_id])
}

# ---- runs -----------------------------------------------------

fun run_create(db, issue_id, agent_id, attempt, state, workspace_path) {
    id = next_id("run")
    _i = db_query(db, "INSERT INTO run (id, issue_id, agent_id, attempt, state, workspace_path, started_at) VALUES (?, ?, ?, ?, ?, ?, ?)", [id, issue_id, agent_id, attempt, state, workspace_path, timestamp()])
    id
}

fun run_finish(db, run_id, state, cost_cents) {
    _u = db_query(db, "UPDATE run SET state = ?, ended_at = ?, cost_cents = CAST(ROUND(?) AS INTEGER) WHERE id = ?", [state, timestamp(), cost_cents, run_id])
    run_id
}

fun runs_all(db) {
    db_query(db, "SELECT id, issue_id, agent_id, attempt, state, workspace_path, started_at, ended_at, cost_cents, verify_state, merge_sha FROM run ORDER BY started_at DESC LIMIT 100", [])
}

fun run_row(db, id) {
    rows = db_query(db, "SELECT id, issue_id, agent_id, attempt, state, workspace_path, started_at, ended_at, cost_cents, verify_state, verify_output, merge_sha FROM run WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

# ---- approvals (governance gate) -----------------------------

fun approval_create(db, company_id, action, payload) {
    id = next_id("apr")
    _i = db_query(db, "INSERT INTO approval (id, company_id, action, payload, requested_by, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)", [id, company_id, action, payload, "operator", "pending", timestamp()])
    id
}

fun approvals_pending(db) {
    db_query(db, "SELECT id, company_id, action, payload, status, created_at FROM approval WHERE status = 'pending' ORDER BY created_at ASC", [])
}

fun approval_row(db, id) {
    rows = db_query(db, "SELECT id, company_id, action, payload, status, decided_at FROM approval WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun approval_set(db, id, status) {
    _u = db_query(db, "UPDATE approval SET status = ?, decided_by = ?, decided_at = ? WHERE id = ?", [status, "operator", timestamp(), id])
    id
}

# ---- activity log --------------------------------------------

fun log_activity(db, company_id, actor, verb, target) {
    id = next_id("act")
    _ins = db_query(db, "INSERT INTO activity (id, company_id, actor, verb, target, ts) VALUES (?, ?, ?, ?, ?, ?)", [id, company_id, actor, verb, target, timestamp()])
    id
}

fun activity_recent(db) {
    db_query(db, "SELECT id, company_id, actor, verb, target, ts FROM activity ORDER BY ts DESC LIMIT 60", [])
}
