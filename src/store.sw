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
        company_add_spend, enforce_budget,
        issues_for, issue_row, issue_create, issue_set_status, issue_assign,
        log_activity, activity_recent, candidate_issues,
        run_create, run_finish, runs_all,
        agents_for, agent_row, agent_first_active, agent_create,
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
    db_query(db, "SELECT id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at FROM company ORDER BY created_at DESC", [])
}

fun company_row(db, id) {
    rows = db_query(db, "SELECT id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at FROM company WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun company_create(db, name, mission, prefix, budget) {
    id = next_id("co")
    now = timestamp()
    _ins = db_query(db, "INSERT INTO company (id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [id, name, mission, prefix, "active", budget, 0, 0, now, now])
    id
}

fun company_update(db, id, budget, status) {
    _u = db_query(db, "UPDATE company SET budget_monthly_cents = ?, status = ?, updated_at = ? WHERE id = ?", [budget, status, timestamp(), id])
    id
}

fun company_add_spend(db, id, cents) {
    _u = db_query(db, "UPDATE company SET spent_cents = spent_cents + CAST(ROUND(?) AS INTEGER), updated_at = ? WHERE id = ?", [cents, timestamp(), id])
    id
}

# The budget hard-stop: if a company has a budget and has reached it,
# flip it to 'paused'. Returns 'paused' if this call paused it, else 'ok'.
fun enforce_budget(db, company_id) {
    rows = db_query(db, "SELECT budget_monthly_cents, spent_cents, status FROM company WHERE id = ?", [company_id])
    if (length(rows) == 0) {
        'ok'
    } else {
        c = hd(rows)
        budget = map_get(c, "budget_monthly_cents")
        spent = map_get(c, "spent_cents")
        status = map_get(c, "status")
        if (budget > 0) {
            if (spent >= budget) {
                if (status == "active") {
                    _u = db_query(db, "UPDATE company SET status = 'paused', updated_at = ? WHERE id = ?", [timestamp(), company_id])
                    'paused'
                } else {
                    'ok'
                }
            } else {
                'ok'
            }
        } else {
            'ok'
        }
    }
}

# ---- issues ---------------------------------------------------

fun issues_for(db, company_id) {
    db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, assignee_agent_id, goal_id, sort_order, created_at, updated_at FROM issue WHERE company_id = ? ORDER BY sort_order ASC", [company_id])
}

fun issue_row(db, id) {
    rows = db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, assignee_agent_id, goal_id, sort_order, created_at, updated_at FROM issue WHERE id = ?", [id])
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
    db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, sort_order FROM issue WHERE status NOT IN ('Done', 'Canceled') AND company_id IN (SELECT id FROM company WHERE status = 'active') ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, created_at ASC", [])
}

# ---- agents ---------------------------------------------------

fun agents_for(db, company_id) {
    db_query(db, "SELECT id, company_id, name, role, department, model, runtime, status, created_at FROM agent WHERE company_id = ? ORDER BY created_at ASC", [company_id])
}

fun agent_row(db, id) {
    rows = db_query(db, "SELECT id, company_id, name, role, department, model, runtime, status, created_at FROM agent WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun agent_first_active(db, company_id) {
    rows = db_query(db, "SELECT id, company_id, name, role, runtime, status FROM agent WHERE company_id = ? AND status = 'active' ORDER BY created_at ASC LIMIT 1", [company_id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun agent_create(db, company_id, name, role, runtime, model) {
    id = next_id("ag")
    _ins = db_query(db, "INSERT INTO agent (id, company_id, name, role, runtime, model, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [id, company_id, name, role, runtime, model, "active", timestamp()])
    id
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
    db_query(db, "SELECT id, issue_id, agent_id, attempt, state, workspace_path, started_at, ended_at, cost_cents FROM run ORDER BY started_at DESC LIMIT 100", [])
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
