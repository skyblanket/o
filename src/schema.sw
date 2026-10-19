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
    # chat keeps its OWN session: claude sessions are scoped to the
    # directory they were created in, so chat (stable ~/.o/chat/<id>)
    # cannot resume a session captured inside an issue worktree.
    _alt_cs = db_exec(db, "ALTER TABLE agent ADD COLUMN chat_session_id TEXT DEFAULT ''")

    # ---- self-improving loop columns (Phase 1) ----------------
    # Each errors harmlessly if the column is already present, so
    # migrate/1 stays idempotent for older control-plane databases.
    _c_repo   = db_exec(db, "ALTER TABLE company ADD COLUMN repo TEXT DEFAULT ''")
    _c_vcmd   = db_exec(db, "ALTER TABLE company ADD COLUMN verify_cmd TEXT DEFAULT ''")
    _c_prot   = db_exec(db, "ALTER TABLE company ADD COLUMN protected_paths TEXT DEFAULT ''")
    _c_bday   = db_exec(db, "ALTER TABLE company ADD COLUMN budget_daily_cents INTEGER DEFAULT 0")
    _c_stoday = db_exec(db, "ALTER TABLE company ADD COLUMN spent_today_cents INTEGER DEFAULT 0")
    _c_bdayn  = db_exec(db, "ALTER TABLE company ADD COLUMN budget_day INTEGER DEFAULT 0")
    _c_prsn   = db_exec(db, "ALTER TABLE company ADD COLUMN pause_reason TEXT DEFAULT ''")
    _c_greens = db_exec(db, "ALTER TABLE company ADD COLUMN greens_today INTEGER DEFAULT 0")
    _c_nosig  = db_exec(db, "ALTER TABLE company ADD COLUMN no_signal_days INTEGER DEFAULT 0")
    _c_lrefl  = db_exec(db, "ALTER TABLE company ADD COLUMN last_reflect_day INTEGER DEFAULT 0")

    # ---- GitHub in/out ----------------------------------------
    # github_repo "owner/name": open issues labelled O_GH_LABEL are imported.
    # ship: "merge" (local serialized merge, the default) or "pr" (push the
    # branch, open a PR, let the repo's CI gate it, merge via gh).
    _c_gh     = db_exec(db, "ALTER TABLE company ADD COLUMN github_repo TEXT DEFAULT ''")
    _c_ship   = db_exec(db, "ALTER TABLE company ADD COLUMN ship TEXT DEFAULT 'merge'")
    # The merge gate's long-lived maintainer session (resumed for every PR,
    # rotated every O_MAINTAINER_ROTATE reviews) and how many reviews it has done.
    _c_msess  = db_exec(db, "ALTER TABLE company ADD COLUMN maintainer_session TEXT DEFAULT ''")
    _c_mrev   = db_exec(db, "ALTER TABLE company ADD COLUMN maintainer_reviews INTEGER DEFAULT 0")

    _i_orig   = db_exec(db, "ALTER TABLE issue ADD COLUMN origin TEXT DEFAULT 'operator'")
    _i_fp     = db_exec(db, "ALTER TABLE issue ADD COLUMN fingerprint TEXT DEFAULT ''")

    _r_vstate = db_exec(db, "ALTER TABLE run ADD COLUMN verify_state TEXT DEFAULT ''")
    _r_vout   = db_exec(db, "ALTER TABLE run ADD COLUMN verify_output TEXT DEFAULT ''")
    _r_msha   = db_exec(db, "ALTER TABLE run ADD COLUMN merge_sha TEXT DEFAULT ''")

    print("  schema     migrated (9 tables)")
}
