# ============================================================
# O v4 — schema.sw  (the SQLite control-plane schema)
# ============================================================
#
# The durable spine. Eight company-scoped tables. Re-runnable:
# every statement is `IF NOT EXISTS`, so migrate/1 is idempotent
# and safe to call on every boot.
#
# Mirrors PRD section 5 (Core Concepts & Data Model).

module Schema

export [migrate]

fun migrate(db) {
    _wal = db_exec(db, "PRAGMA journal_mode=WAL")
    _fk  = db_exec(db, "PRAGMA foreign_keys=ON")
    _bt  = db_exec(db, "PRAGMA busy_timeout=5000")

    _company = db_exec(db, "CREATE TABLE IF NOT EXISTS company (id TEXT PRIMARY KEY, name TEXT NOT NULL, mission TEXT, issue_prefix TEXT, status TEXT, budget_monthly_cents INTEGER DEFAULT 0, spent_cents INTEGER DEFAULT 0, issue_counter INTEGER DEFAULT 0, created_at INTEGER, updated_at INTEGER)")

    _goal = db_exec(db, "CREATE TABLE IF NOT EXISTS goal (id TEXT PRIMARY KEY, company_id TEXT NOT NULL, parent_goal_id TEXT, title TEXT NOT NULL, status TEXT, created_at INTEGER)")

    _agent = db_exec(db, "CREATE TABLE IF NOT EXISTS agent (id TEXT PRIMARY KEY, company_id TEXT NOT NULL, name TEXT NOT NULL, role TEXT, department TEXT, manager_id TEXT, model TEXT, runtime TEXT, repo TEXT DEFAULT '', session_id TEXT DEFAULT '', budget_cents INTEGER DEFAULT 0, status TEXT, created_at INTEGER)")

    _issue = db_exec(db, "CREATE TABLE IF NOT EXISTS issue (id TEXT PRIMARY KEY, company_id TEXT NOT NULL, identifier TEXT, title TEXT NOT NULL, body TEXT, status TEXT, priority TEXT, assignee_agent_id TEXT, goal_id TEXT, blocked_by TEXT, sort_order INTEGER, created_at INTEGER, updated_at INTEGER)")

    _run = db_exec(db, "CREATE TABLE IF NOT EXISTS run (id TEXT PRIMARY KEY, issue_id TEXT NOT NULL, agent_id TEXT, attempt INTEGER DEFAULT 1, state TEXT, workspace_path TEXT, thread_id TEXT, started_at INTEGER, ended_at INTEGER, tokens_in INTEGER DEFAULT 0, tokens_out INTEGER DEFAULT 0, cost_cents INTEGER DEFAULT 0)")

    _approval = db_exec(db, "CREATE TABLE IF NOT EXISTS approval (id TEXT PRIMARY KEY, company_id TEXT NOT NULL, action TEXT, payload TEXT, requested_by TEXT, status TEXT, decided_by TEXT, decided_at INTEGER, created_at INTEGER)")

    _activity = db_exec(db, "CREATE TABLE IF NOT EXISTS activity (id TEXT PRIMARY KEY, company_id TEXT, actor TEXT, verb TEXT, target TEXT, payload TEXT, ts INTEGER)")

    _skill = db_exec(db, "CREATE TABLE IF NOT EXISTS skill (id TEXT PRIMARY KEY, name TEXT NOT NULL, frontmatter TEXT, body TEXT, scope TEXT, created_at INTEGER)")

    # Operator <-> agent chat. role is 'operator' or 'agent'. A chat
    # turn runs against the agent's persistent session, so chatting
    # with an agent shares context with the issues it has worked.
    _message = db_exec(db, "CREATE TABLE IF NOT EXISTS message (id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, role TEXT, content TEXT, created_at INTEGER)")

    _ix1 = db_exec(db, "CREATE INDEX IF NOT EXISTS ix_issue_company ON issue (company_id)")
    _ix2 = db_exec(db, "CREATE INDEX IF NOT EXISTS ix_agent_company ON agent (company_id)")
    _ix3 = db_exec(db, "CREATE INDEX IF NOT EXISTS ix_run_issue ON run (issue_id)")
    _ix4 = db_exec(db, "CREATE INDEX IF NOT EXISTS ix_activity_company ON activity (company_id)")
    _ix5 = db_exec(db, "CREATE INDEX IF NOT EXISTS ix_message_agent ON message (agent_id)")

    # additive columns for older databases (error harmlessly if present)
    _alt = db_exec(db, "ALTER TABLE agent ADD COLUMN repo TEXT DEFAULT ''")
    _alt_ses = db_exec(db, "ALTER TABLE agent ADD COLUMN session_id TEXT DEFAULT ''")

    print("  schema     migrated (9 tables)")
}
