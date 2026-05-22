# ============================================================
# O v4 — store.sw  (data-access layer over the SQLite spine)
# ============================================================
#
# Every function is company-scoped and returns plain sw values
# (row maps / lists of row maps) so callers can json_encode them
# directly. No business logic here — just persistence.

module Store

export [next_id, companies, company_row, company_create,
        issues_for, issue_row, issue_create, issue_set_status, issue_assign,
        log_activity, candidate_issues,
        run_create, run_mark, runs_all,
        agents_for, agent_row, agent_first_active, agent_create]

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

fun company_create(db, name, mission, prefix) {
    id = next_id("co")
    now = timestamp()
    _ins = db_query(db, "INSERT INTO company (id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [id, name, mission, prefix, "active", 0, 0, 0, now, now])
    id
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

# Non-terminal issues, highest priority first, then oldest first.
fun candidate_issues(db) {
    db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, sort_order FROM issue WHERE status NOT IN ('Done', 'Canceled') ORDER BY CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, created_at ASC", [])
}

# ---- agents ---------------------------------------------------

fun agents_for(db, company_id) {
    db_query(db, "SELECT id, company_id, name, role, department, model, runtime, status, created_at FROM agent WHERE company_id = ? ORDER BY created_at ASC", [company_id])
}

fun agent_row(db, id) {
    rows = db_query(db, "SELECT id, company_id, name, role, department, model, runtime, status, created_at FROM agent WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

# The agent the orchestrator hands work to. P2: first active agent.
# P3 routes by role / department / org chart.
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

fun run_mark(db, run_id, state) {
    _u = db_query(db, "UPDATE run SET state = ?, ended_at = ? WHERE id = ?", [state, timestamp(), run_id])
    run_id
}

fun runs_all(db) {
    db_query(db, "SELECT id, issue_id, agent_id, attempt, state, workspace_path, started_at, ended_at, tokens_in, tokens_out, cost_cents FROM run ORDER BY started_at DESC LIMIT 100", [])
}

# ---- activity log --------------------------------------------

fun log_activity(db, company_id, actor, verb, target) {
    id = next_id("act")
    _ins = db_query(db, "INSERT INTO activity (id, company_id, actor, verb, target, ts) VALUES (?, ?, ?, ?, ?, ?)", [id, company_id, actor, verb, target, timestamp()])
    id
}
