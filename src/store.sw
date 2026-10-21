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
        company_touch_reflect, companies_to_reflect, company_set_github, companies_with_github, company_set_maintainer, issues_in_review,
        issues_for, issue_row, issue_create, issue_create_auto, issue_create_with_origin, issue_open_fp_count, issue_import_github,
        issue_set_status, issue_assign, issue_update, open_issue_titles,
        log_activity, activity_recent, activity_since, candidate_issues,
        failed_runs_for,
        run_create, run_finish, run_set_state, run_set_verify, run_set_merge, last_run_for_issue, run_count_for_issue, runs_all, run_row,
        agents_for, agent_row, agent_first_active, agent_create,
        agent_set_session, agent_set_chat_session,
        message_create, messages_for,
        approval_create, approvals_pending, approval_row, approval_set,
        persona_create, persona_row, personas_for, persona_set, personas_due, persona_touch,
        companies_persona_due, company_touch_persona, company_add_persona_spend,
        persona_run_create, persona_run_row, persona_runs_for, persona_run_report, persona_run_finish, persona_run_add_report,
        issue_link_persona, issue_open_by_fp, issue_append_body,
        persona_confirm_due, issue_set_scenario_state, company_set_persona,
        persona_run_set_issue, persona_runs_reap, persona_confirms_running]

# Ask the registered `idgen` process for a fresh unique id.
fun next_id(prefix) {
    send(whereis('idgen'), {'gen', self(), prefix})
    receive {
        {'id', x} -> x
    }
}

# ---- companies ------------------------------------------------

fun companies(db) {
    db_query(db, "SELECT id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at, repo, verify_cmd, protected_paths, budget_daily_cents, spent_today_cents, budget_day, pause_reason, greens_today, no_signal_days, last_reflect_day, github_repo, ship, maintainer_session, maintainer_reviews, persona_daily_cents, persona_spent_today, personas_per_day, last_persona_day FROM company ORDER BY created_at DESC", [])
}

fun company_row(db, id) {
    rows = db_query(db, "SELECT id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at, repo, verify_cmd, protected_paths, budget_daily_cents, spent_today_cents, budget_day, pause_reason, greens_today, no_signal_days, last_reflect_day, github_repo, ship, maintainer_session, maintainer_reviews, persona_daily_cents, persona_spent_today, personas_per_day, last_persona_day FROM company WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun company_create(db, name, mission, prefix, budget, repo, verify_cmd, protected_paths, budget_daily) {
    id = next_id("co")
    now = timestamp()
    # budget_day starts at TODAY: creating a company is not a day rollover.
    # (At 0 the next tick rolled it over, racing any write made right after
    # creation, such as a test arming the no-signal breaker.)
    _ins = db_query(db, "INSERT INTO company (id, name, mission, issue_prefix, status, budget_monthly_cents, spent_cents, issue_counter, created_at, updated_at, repo, verify_cmd, protected_paths, budget_daily_cents, budget_day) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? / 86400000)", [id, name, mission, prefix, "active", budget, 0, 0, now, now, repo, verify_cmd, protected_paths, budget_daily, now])
    id
}

fun company_update(db, id, budget, status, repo, verify_cmd, protected_paths, budget_daily) {
    _u = db_query(db, "UPDATE company SET budget_monthly_cents = ?, status = ?, repo = ?, verify_cmd = ?, protected_paths = ?, budget_daily_cents = ?, updated_at = ? WHERE id = ?", [budget, status, repo, verify_cmd, protected_paths, budget_daily, timestamp(), id])
    id
}

fun company_set_github(db, id, github_repo, ship) {
    _u = db_query(db, "UPDATE company SET github_repo = ?, ship = ?, updated_at = ? WHERE id = ?", [github_repo, ship, timestamp(), id])
    id
}

# Issues parked In Review on a PR-mode company: what the review poller
# watches for a human merge or close (and, with the merge gate on, adopts).
fun issues_in_review(db) {
    db_query(db, "SELECT i.id, i.company_id, c.github_repo, c.repo FROM issue i JOIN company c ON c.id = i.company_id WHERE i.status = 'In Review' AND c.status = 'active' AND c.ship = 'pr' AND c.github_repo != ''", [])
}

# Issues on a PR-mode company that ran at least once but are not parked In
# Review: a human may have merged their PR anyway (the self-check looks).
fun issues_maybe_merged(db) {
    db_query(db, "SELECT i.id, i.company_id, c.github_repo FROM issue i JOIN company c ON c.id = i.company_id WHERE i.status IN ('Failed', 'Backlog', 'Todo', 'In Progress', 'Verifying') AND c.status = 'active' AND c.ship = 'pr' AND c.github_repo != '' AND EXISTS (SELECT 1 FROM run r WHERE r.issue_id = i.id)", [])
}

# In Review issues whose latest run ended red: nothing will ever pick them up.
fun issues_stranded_in_review(db) {
    db_query(db, "SELECT i.id, i.company_id FROM issue i WHERE i.status = 'In Review' AND (SELECT r.verify_state FROM run r WHERE r.issue_id = i.id ORDER BY r.started_at DESC LIMIT 1) LIKE 'red_%'", [])
}

# Open issues whose worktree may need a health check.
fun issues_with_workspace(db) {
    db_query(db, "SELECT i.id, i.company_id, c.repo FROM issue i JOIN company c ON c.id = i.company_id WHERE i.status NOT IN ('Done', 'Canceled', 'Reverted') AND c.repo != ''", [])
}

fun activity_count_since(db, verb, since) {
    r = db_query(db, "SELECT COUNT(*) AS n FROM activity WHERE verb = ? AND ts >= ?", [verb, since])
    if (length(r) == 0) { 0 } else { map_get(hd(r), "n") }
}

fun company_set_maintainer(db, id, session, reviews) {
    _u = db_query(db, "UPDATE company SET maintainer_session = ?, maintainer_reviews = ?, updated_at = ? WHERE id = ?", [session, reviews, timestamp(), id])
    id
}

# Active companies wired to a GitHub repo — the issue-import poll set.
fun companies_with_github(db) {
    db_query(db, "SELECT id, github_repo FROM company WHERE status = 'active' AND github_repo != ''", [])
}

# PR-mode companies: the ones whose main the post-merge check watches.
fun companies_pr_mode(db) {
    db_query(db, "SELECT id, repo, github_repo, verify_cmd FROM company WHERE status = 'active' AND ship = 'pr' AND github_repo != '' AND repo != ''", [])
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

# Daily rollover. The epoch-day is computed IN SQL (int/int in SQLite) so
# no sw float→int is needed. For every company whose stored budget_day is
# not today this:
#   (a) evaluates the NO-SIGNAL breaker on the about-to-be-reset counters:
#       if budget_daily_cents > 0 AND spent_today_cents >= 80% of it AND
#       greens_today == 0, no_signal_days += 1 (else it resets to 0). If the
#       incremented value >= `threshold`, the company is paused with
#       pause_reason='no-signal'.
#   (b) resets the daily spend + green counters and stamps the new day.
#   (c) un-pauses a company that was stopped on the DAILY budget cap — but
#       NOT one paused for 'no-signal' (that breaker holds until an operator
#       clears it), and a monthly hard-stop survives too.
# Runs one UPDATE per rolled company (no bulk sweep) so each carries its own
# computed no_signal_days + status. Returns a list of per-company info maps
# %{id, result, no_signal_days} so the ORCHESTRATOR logs budget.reset /
# budget.no_signal and auto-files the diagnostic issue. `result` is a STRING:
# "paused" (no-signal tripped) | "unpaused" (budget-daily lifted) | "reset".
fun rollover_day(db, now_ms, threshold) {
    rows = db_query(db, "SELECT id, budget_daily_cents, spent_today_cents, greens_today, no_signal_days, pause_reason FROM company WHERE budget_day != (? / 86400000)", [now_ms])
    rollover_each(db, rows, now_ms, threshold)
}

fun rollover_each(db, rows, now_ms, threshold) {
    if (length(rows) == 0) {
        []
    } else {
        info = rollover_one(db, hd(rows), now_ms, threshold)
        [info] ++ rollover_each(db, tl(rows), now_ms, threshold)
    }
}

fun rollover_one(db, c, now_ms, threshold) {
    cid = map_get(c, "id")
    budget_daily = map_get(c, "budget_daily_cents")
    spent_today = map_get(c, "spent_today_cents")
    greens = map_get(c, "greens_today")
    prior = map_get(c, "no_signal_days")
    pause_reason = map_get(c, "pause_reason")
    # 80% threshold with integer math (no float→int): spent*10 >= budget*8.
    incremented = if (budget_daily > 0 && greens == 0 && (spent_today * 10) >= (budget_daily * 8)) { 'true' } else { 'false' }
    new_nosig = if (incremented == 'true') { prior + 1 } else { 0 }
    tripped = if (incremented == 'true' && new_nosig >= threshold) { 'true' } else { 'false' }
    now = timestamp()
    if (tripped == 'true') {
        _u = db_query(db, "UPDATE company SET spent_today_cents = 0, persona_spent_today = 0, greens_today = 0, budget_day = (? / 86400000), no_signal_days = ?, status = 'paused', pause_reason = 'no-signal', updated_at = ? WHERE id = ?", [now_ms, new_nosig, now, cid])
        %{id: cid, result: "paused", no_signal_days: new_nosig}
    } else {
        if (pause_reason == "budget-daily") {
            _u = db_query(db, "UPDATE company SET spent_today_cents = 0, persona_spent_today = 0, greens_today = 0, budget_day = (? / 86400000), no_signal_days = ?, status = 'active', pause_reason = '', updated_at = ? WHERE id = ?", [now_ms, new_nosig, now, cid])
            %{id: cid, result: "unpaused", no_signal_days: new_nosig}
        } else {
            _u = db_query(db, "UPDATE company SET spent_today_cents = 0, persona_spent_today = 0, greens_today = 0, budget_day = (? / 86400000), no_signal_days = ?, updated_at = ? WHERE id = ?", [now_ms, new_nosig, now, cid])
            %{id: cid, result: "reset", no_signal_days: new_nosig}
        }
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
    rows = db_query(db, "SELECT COALESCE(SUM(spent_today_cents + persona_spent_today), 0) AS total FROM company", [])
    if (length(rows) == 0) { 0 } else { map_get(hd(rows), "total") }
}

# ---- daily reflection (Phase 5) -------------------------------
# Stamp last_reflect_day = today (epoch-day computed IN SQL, no sw float→int).
# Called BEFORE the reflect worker is spawned, so reflection is at-most-once
# per company per day even if the worker run itself fails.
fun company_touch_reflect(db, id, now_ms) {
    _u = db_query(db, "UPDATE company SET last_reflect_day = (? / 86400000), updated_at = ? WHERE id = ?", [now_ms, timestamp(), id])
    id
}

# Active companies with a repo whose last_reflect_day is before today — the
# candidates for a daily reflection pass. Epoch-day computed IN SQL.
fun companies_to_reflect(db, now_ms) {
    db_query(db, "SELECT id, name, repo FROM company WHERE status = 'active' AND repo != '' AND last_reflect_day < (? / 86400000)", [now_ms])
}

# ---- issues ---------------------------------------------------

fun issues_for(db, company_id) {
    db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, assignee_agent_id, goal_id, sort_order, created_at, updated_at, origin, fingerprint FROM issue WHERE company_id = ? ORDER BY sort_order ASC", [company_id])
}

fun issue_row(db, id) {
    rows = db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, assignee_agent_id, goal_id, sort_order, created_at, updated_at, origin, fingerprint, persona_id, verify_scenario_after_fix FROM issue WHERE id = ?", [id])
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

# The self-file cap: max auto/reflect issues a company may file per day.
# O_SELF_FILE_CAP overrides; default 10.
fun self_file_cap() {
    v = getenv("O_SELF_FILE_CAP")
    if (v == nil) {
        10
    } else {
        n = to_int(v)
        if (n == nil) { 10 } else { n }
    }
}

# Count of OPEN (non-terminal) issues in a company carrying this exact
# fingerprint. The dedup key for auto-filing: a caller that got nil back
# from issue_create_auto uses this to tell "duped" (>0) from "capped" (0).
fun issue_open_fp_count(db, company_id, fingerprint) {
    rows = db_query(db, "SELECT COUNT(*) AS n FROM issue WHERE company_id = ? AND fingerprint = ? AND status NOT IN ('Done', 'Canceled', 'Failed', 'Reverted')", [company_id, fingerprint])
    if (length(rows) == 0) { 0 } else { map_get(hd(rows), "n") }
}

# Auto-file an issue on the loop's own behalf (origin 'auto'/'reflect'),
# with two guard rails:
#   dedup  — a non-empty fingerprint that already matches an OPEN issue in
#            this company returns nil (the caller logs "selffile.duped").
#   daily cap — if the company already filed self_file_cap() auto/reflect
#            issues TODAY, returns nil (the caller logs "selffile.capped").
# Otherwise it creates the issue exactly like issue_create but with the
# origin + fingerprint columns set, and returns the new id.
fun issue_create_auto(db, company_id, title, body, priority, origin, fingerprint) {
    crow = company_row(db, company_id)
    if (crow == nil) {
        nil
    } else {
        now = timestamp()
        dup = if (string_length(fingerprint) == 0) {
            0
        } else {
            issue_open_fp_count(db, company_id, fingerprint)
        }
        if (dup > 0) {
            nil
        } else {
            caprows = db_query(db, "SELECT COUNT(*) AS n FROM issue WHERE company_id = ? AND origin IN ('auto', 'reflect', 'persona') AND (created_at / 86400000) = (? / 86400000)", [company_id, now])
            filed_today = if (length(caprows) == 0) { 0 } else { map_get(hd(caprows), "n") }
            if (filed_today >= self_file_cap()) {
                nil
            } else {
                prefix = map_get(crow, "issue_prefix")
                n = map_get(crow, "issue_counter") + 1
                identifier = f"{prefix}-{n}"
                id = next_id("iss")
                _upd = db_query(db, "UPDATE company SET issue_counter = ?, updated_at = ? WHERE id = ?", [n, now, company_id])
                _ins = db_query(db, "INSERT INTO issue (id, company_id, identifier, title, body, status, priority, sort_order, created_at, updated_at, origin, fingerprint) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [id, company_id, identifier, title, body, "Backlog", priority, now, now, now, origin, fingerprint])
                id
            }
        }
    }
}

# Create an issue with an explicit origin (e.g. 'feedback') and NO
# fingerprint — deliberately NOT routed through the auto/reflect self-file
# cap (issue_create_auto caps only origin IN ('auto','reflect')). Operator-
# adjacent intake paths (the Phase-6b visual feedback widget) use this so a
# human's feedback is never silently swallowed by the loop's own daily cap.
# Returns the new issue id, or nil if the company does not exist.
fun issue_create_with_origin(db, company_id, title, body, priority, origin) {
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
        _ins = db_query(db, "INSERT INTO issue (id, company_id, identifier, title, body, status, priority, sort_order, created_at, updated_at, origin, fingerprint) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [id, company_id, identifier, title, body, "Backlog", priority, now, now, now, origin, ""])
        id
    }
}

# Import GitHub issue #number exactly once per company, ever: the fingerprint
# gh:<number> is checked across ALL statuses, so a closed-out O issue is never
# re-imported while its GitHub issue stays open. Returns the new id or nil.
fun issue_import_github(db, company_id, number, title, body) {
    fp = f"gh:{number}"
    rows = db_query(db, "SELECT COUNT(*) AS n FROM issue WHERE company_id = ? AND fingerprint = ?", [company_id, fp])
    seen = if (length(rows) == 0) { 0 } else { map_get(hd(rows), "n") }
    crow = company_row(db, company_id)
    if (seen > 0 || crow == nil) {
        nil
    } else {
        prefix = map_get(crow, "issue_prefix")
        n = map_get(crow, "issue_counter") + 1
        identifier = f"{prefix}-{n}"
        id = next_id("iss")
        now = timestamp()
        _upd = db_query(db, "UPDATE company SET issue_counter = ?, updated_at = ? WHERE id = ?", [n, now, company_id])
        _ins = db_query(db, "INSERT INTO issue (id, company_id, identifier, title, body, status, priority, sort_order, created_at, updated_at, origin, fingerprint) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [id, company_id, identifier, title, body, "Backlog", "medium", now, now, now, "github", fp])
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
#
# "Verifying" is deliberately NOT excluded: an issue mid-verify/mid-merge is a
# candidate for CRASH RECOVERY — if the daemon restarts, the in-memory running
# map is empty, so a stuck "Verifying" issue must be re-dispatchable. While the
# daemon is alive the running map holds that issue, and dispatch_batch skips any
# id already in running, so no double-dispatch occurs. Only "Reverted" (a phase-3
# terminal state) joins Done/Canceled/Failed in the exclusion list.
fun candidate_issues(db) {
    db_query(db, "SELECT id, company_id, identifier, title, body, status, priority, assignee_agent_id, sort_order, origin, fingerprint FROM issue WHERE status NOT IN ('Done', 'Canceled', 'Failed', 'Reverted', 'In Review') AND company_id IN (SELECT id FROM company WHERE status = 'active') ORDER BY CASE WHEN origin = 'auto' THEN 0 ELSE 1 END, CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END, created_at ASC", [])
}

# Partial update of the operator-editable issue fields.
fun issue_update(db, id, status, priority, assignee) {
    _u = db_query(db, "UPDATE issue SET status = ?, priority = ?, assignee_agent_id = ?, updated_at = ? WHERE id = ?", [status, priority, assignee, timestamp(), id])
    id
}

# Open (non-terminal) issue identifiers + titles for a company — the reflection
# pass reads these so it never re-files work already tracked.
fun open_issue_titles(db, company_id) {
    db_query(db, "SELECT identifier, title, priority, origin, status FROM issue WHERE company_id = ? AND status NOT IN ('Done', 'Canceled', 'Failed', 'Reverted') ORDER BY created_at DESC LIMIT 50", [company_id])
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

# Add a later stage's cost (review, merge gate) to the run, on top of the
# builder's cost that run_finish stored.
fun run_add_cost(db, run_id, cost_cents) {
    db_query(db, "UPDATE run SET cost_cents = cost_cents + CAST(ROUND(?) AS INTEGER) WHERE id = ?", [cost_cents, run_id])
}

# Everything an issue's runs have cost, in cents.
fun issue_cost(db, iid) {
    rows = db_query(db, "SELECT COALESCE(SUM(cost_cents), 0) AS c FROM run WHERE issue_id = ?", [iid])
    if (length(rows) == 0) { 0 } else { map_get(hd(rows), "c") }
}

# The Claude session a run worked in; its issue's retry resumes it.
fun run_set_thread(db, run_id, sid) {
    _u = db_query(db, "UPDATE run SET thread_id = ? WHERE id = ?", [sid, run_id])
    run_id
}

fun run_finish(db, run_id, state, cost_cents) {
    _u = db_query(db, "UPDATE run SET state = ?, ended_at = ?, cost_cents = CAST(ROUND(?) AS INTEGER) WHERE id = ?", [state, timestamp(), cost_cents, run_id])
    run_id
}

# Set ONLY the run's lifecycle state — never touches cost_cents. Used to
# advance a run out of "Verifying" (whose cost was already written when it
# entered the verify phase) without run_finish clobbering that cost to 0.
fun run_set_state(db, run_id, state) {
    _u = db_query(db, "UPDATE run SET state = ? WHERE id = ?", [state, run_id])
    run_id
}

# Record the grounded verifier's verdict + a tail of its output. Output is
# hard-truncated to ~4KB so a runaway test log can't bloat the control plane.
fun run_set_verify(db, run_id, state, output) {
    tail = string_truncate(output, 4096)
    _u = db_query(db, "UPDATE run SET verify_state = ?, verify_output = ? WHERE id = ?", [state, tail, run_id])
    run_id
}

# Record the merge commit sha once a run merges (or reverts) on main. The
# forensic pointer for a "Reverted" run and the success marker for a merged one.
fun run_set_merge(db, run_id, sha) {
    _u = db_query(db, "UPDATE run SET merge_sha = ? WHERE id = ?", [sha, run_id])
    run_id
}

# The latest run for an issue by start time — carries the verify verdict +
# output the next attempt's structured-retry prompt reads. nil if none.
# How many of an issue's runs a restart interrupted at this attempt.
fun abandoned_at(db, issue_id, attempt) {
    rows = db_query(db, "SELECT COUNT(*) AS n FROM run WHERE issue_id = ? AND attempt = ? AND state = 'Abandoned'", [issue_id, attempt])
    if (length(rows) == 0) { 0 } else { map_get(hd(rows), "n") }
}

fun run_count_for_issue(db, issue_id) {
    rows = db_query(db, "SELECT COUNT(*) AS n FROM run WHERE issue_id = ?", [issue_id])
    if (length(rows) == 0) { 0 } else { map_get(hd(rows), "n") }
}

# Every graded attempt on an issue, oldest first: what O tried, for the note
# it leaves when it stops.
fun run_history(db, issue_id) {
    db_query(db, "SELECT attempt, verify_state, verify_output FROM run WHERE issue_id = ? AND verify_state != '' ORDER BY started_at", [issue_id])
}

# How many times an operator sent this issue back for another round.
fun retry_count(db, issue_id) {
    rows = db_query(db, "SELECT COUNT(*) AS n FROM activity WHERE verb = 'issue.retry' AND target = ?", [issue_id])
    if (length(rows) == 0) { 0 } else { map_get(hd(rows), "n") }
}

fun last_run_for_issue(db, issue_id) {
    rows = db_query(db, "SELECT id, issue_id, agent_id, attempt, state, verify_state, verify_output, started_at, thread_id FROM run WHERE issue_id = ? ORDER BY started_at DESC LIMIT 1", [issue_id])
    if (length(rows) == 0) { nil } else { hd(rows) }
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

# A company's activity since `since_ms` (the reflection pass reads the last 24h).
fun activity_since(db, company_id, since_ms) {
    db_query(db, "SELECT actor, verb, target, ts FROM activity WHERE company_id = ? AND ts >= ? ORDER BY ts DESC LIMIT 100", [company_id, since_ms])
}

# A company's failed / reverted / stalled runs, newest first, with the verify
# verdict + output tail each carried — the grounded material the reflection pass
# reasons over. Joined through issue to scope by company.
fun failed_runs_for(db, company_id) {
    db_query(db, "SELECT r.state AS state, r.verify_state AS verify_state, r.verify_output AS verify_output, i.identifier AS identifier, i.title AS title FROM run r JOIN issue i ON r.issue_id = i.id WHERE i.company_id = ? AND r.state IN ('Failed', 'Reverted', 'VerifyFailed', 'Stalled') ORDER BY r.started_at DESC LIMIT 20", [company_id])
}

# ============================================================
# Persona pass
# ============================================================
fun persona_create(db, company_id, name, role, goal, start, done_when, model) {
    id = next_id("per")
    _i = db_query(db, "INSERT INTO persona (id, company_id, name, role, goal, start, done_when, model, enabled, last_run_day, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?)", [id, company_id, name, role, goal, start, done_when, model, timestamp()])
    id
}

fun persona_row(db, id) {
    rows = db_query(db, "SELECT id, company_id, name, role, goal, start, done_when, model, enabled, last_run_day, created_at FROM persona WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun personas_for(db, company_id) {
    db_query(db, "SELECT id, company_id, name, role, goal, start, done_when, model, enabled, last_run_day, created_at FROM persona WHERE company_id = ? ORDER BY created_at ASC", [company_id])
}

fun persona_set(db, id, name, role, goal, start, done_when, model, enabled) {
    _u = db_query(db, "UPDATE persona SET name = ?, role = ?, goal = ?, start = ?, done_when = ?, model = ?, enabled = ? WHERE id = ?", [name, role, goal, start, done_when, model, enabled, id])
    id
}

# Up to n enabled personas, least recently run first, so each gets a turn.
fun personas_due(db, company_id, n) {
    db_query(db, "SELECT id, company_id, name, role, goal, start, done_when, model FROM persona WHERE company_id = ? AND enabled = 1 ORDER BY last_run_day ASC, created_at ASC LIMIT ?", [company_id, n])
}

fun persona_touch(db, id, now_ms) {
    _u = db_query(db, "UPDATE persona SET last_run_day = (? / 86400000) WHERE id = ?", [now_ms, id])
    id
}

# Active companies whose persona pass hasn't run today.
fun companies_persona_due(db, now_ms) {
    db_query(db, "SELECT id, repo, personas_per_day, persona_daily_cents, persona_spent_today FROM company WHERE status = 'active' AND repo != '' AND last_persona_day < (? / 86400000)", [now_ms])
}

fun company_touch_persona(db, id, now_ms) {
    _u = db_query(db, "UPDATE company SET last_persona_day = (? / 86400000), updated_at = ? WHERE id = ?", [now_ms, timestamp(), id])
    id
}

fun company_add_persona_spend(db, id, cents) {
    _u = db_query(db, "UPDATE company SET persona_spent_today = persona_spent_today + CAST(ROUND(?) AS INTEGER) WHERE id = ?", [cents, id])
    id
}

fun persona_run_create(db, persona_id, company_id, kind, for_issue_id) {
    id = next_id("prun")
    _i = db_query(db, "INSERT INTO persona_run (id, persona_id, company_id, kind, started_at, outcome, report, cost_cents, issue_id, for_issue_id) VALUES (?, ?, ?, ?, ?, 'running', '', 0, '', ?)", [id, persona_id, company_id, kind, timestamp(), for_issue_id])
    id
}

fun persona_run_row(db, id) {
    rows = db_query(db, "SELECT id, persona_id, company_id, kind, started_at, ended_at, outcome, report, cost_cents, issue_id, for_issue_id FROM persona_run WHERE id = ?", [id])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun persona_runs_for(db, company_id) {
    db_query(db, "SELECT r.id, r.persona_id, p.name AS persona, r.kind, r.started_at, r.ended_at, r.outcome, r.report, r.cost_cents, r.issue_id, r.for_issue_id FROM persona_run r LEFT JOIN persona p ON p.id = r.persona_id WHERE r.company_id = ? ORDER BY r.started_at DESC LIMIT 200", [company_id])
}

fun persona_run_report(db, run_id, outcome, report, issue_id) {
    _u = db_query(db, "UPDATE persona_run SET outcome = ?, report = ?, issue_id = ? WHERE id = ?", [outcome, report, issue_id, run_id])
    run_id
}

# A persona POSTs its findings while it runs; each report is appended to the
# run's JSON list and the run is marked "reported". The orchestrator files
# them when the run finishes (so the router never blocks on a judge call).
fun persona_run_add_report(db, run_id, report) {
    row = persona_run_row(db, run_id)
    raw = map_get(row, "report")
    cur = if (raw == nil) { [] } else { if (string_length(raw) == 0) { [] } else { json_decode(raw) } }
    _u = db_query(db, "UPDATE persona_run SET outcome = 'reported', report = ? WHERE id = ?", [json_encode(cur ++ [report]), run_id])
    length(cur) + 1
}

# The worker finished: record cost and end time. A run still "running" (it
# filed nothing) ends as `quiet` (a clean pass), or "error" if the worker failed.
fun persona_run_finish(db, run_id, cost, quiet) {
    _u = db_query(db, "UPDATE persona_run SET ended_at = ?, cost_cents = CAST(ROUND(?) AS INTEGER), outcome = CASE WHEN outcome = 'running' THEN ? ELSE outcome END WHERE id = ?", [timestamp(), cost, quiet, run_id])
    persona_run_row(db, run_id)
}

# Persona-found issues that reached Done and still owe a confirmation run
# (verify_scenario_after_fix: 1 = owed, 2 = running, 3 = settled).
fun persona_confirm_due(db) {
    db_query(db, "SELECT i.id, i.company_id, i.identifier, i.title, i.persona_id, i.origin, i.fingerprint FROM issue i JOIN company c ON c.id = i.company_id WHERE i.verify_scenario_after_fix = 1 AND i.status = 'Done' AND i.persona_id != '' AND c.status = 'active' LIMIT 1", [])
}

fun persona_run_set_issue(db, run_id, issue_id) {
    _u = db_query(db, "UPDATE persona_run SET issue_id = ? WHERE id = ?", [issue_id, run_id])
    run_id
}

# A worker that died without reporting back leaves its run "running" forever;
# anything older than `older_than_ms` is closed out as an error.
fun persona_runs_reap(db, cutoff) {
    _u = db_query(db, "UPDATE persona_run SET outcome = 'error', ended_at = ? WHERE ended_at = 0 AND started_at < ?", [timestamp(), cutoff])
    ""
}

fun persona_confirms_running(db) {
    rows = db_query(db, "SELECT COUNT(*) AS n FROM persona_run WHERE kind = 'confirm' AND ended_at = 0", [])
    if (length(rows) == 0) { 0 } else { map_get(hd(rows), "n") }
}

fun issue_set_scenario_state(db, id, v) {
    _u = db_query(db, "UPDATE issue SET verify_scenario_after_fix = ? WHERE id = ?", [v, id])
    id
}

fun company_set_persona(db, id, daily_cents, per_day) {
    _u = db_query(db, "UPDATE company SET persona_daily_cents = ?, personas_per_day = ?, updated_at = ? WHERE id = ?", [daily_cents, per_day, timestamp(), id])
    id
}

fun issue_link_persona(db, issue_id, persona_id) {
    _u = db_query(db, "UPDATE issue SET persona_id = ?, verify_scenario_after_fix = 1 WHERE id = ?", [persona_id, issue_id])
    issue_id
}

fun issue_open_by_fp(db, company_id, fp) {
    rows = db_query(db, "SELECT id, body FROM issue WHERE company_id = ? AND fingerprint = ? AND status NOT IN ('Done', 'Canceled', 'Failed', 'Reverted')", [company_id, fp])
    if (length(rows) == 0) { nil } else { hd(rows) }
}

fun issue_append_body(db, id, text) {
    _u = db_query(db, "UPDATE issue SET body = body || ?, updated_at = ? WHERE id = ?", [text, timestamp(), id])
    id
}

# ---- proof: is O actually maintaining the repo? ---------------------
# All time, from the activity log. "By O" is a merge O made itself (local
# merge or its gate merging the PR); "by a human" is a PR a person merged
# (a sign-off). Escaped = an O-merged change reverted after merge, or a fix a
# persona re-ran and found still broken. Touches = every time a person had to
# act: a sign-off, a protected-file edit O asked for, a retry or a manual edit.
fun count_target_verb(db, target, verb) {
    r = db_query(db, "SELECT COUNT(*) AS n FROM activity WHERE target = ? AND verb = ?", [target, verb])
    if (length(r) == 0) { 0 } else { map_get(hd(r), "n") }
}

fun count_verbs(db, verbs) {
    marks = Std.join(["?" for v in verbs], ", ")
    r = db_query(db, "SELECT COUNT(*) AS n FROM activity WHERE verb IN (" ++ marks ++ ")", verbs)
    if (length(r) == 0) { 0 } else { map_get(hd(r), "n") }
}

fun proof(db) {
    by_o = count_verbs(db, ["ci.merged", "merge.done"])
    by_human = count_verbs(db, ["pr.merged"])
    escaped = count_verbs(db, ["merge.revert", "persona.still_broken"])
    touches = count_verbs(db, ["pr.merged", "run.needs_human", "issue.retry", "issue.update"])
    caught = count_verbs(db, ["review.reject", "gate.reject", "ci.fail", "verify.fail"])
    rc = db_query(db, "SELECT COALESCE(SUM(cost_cents), 0) AS c, COUNT(*) AS n FROM run", [])
    cents = if (length(rc) == 0) { 0 } else { map_get(hd(rc), "c") }
    runs = if (length(rc) == 0) { 0 } else { map_get(hd(rc), "n") }
    merges = by_o + by_human
    # per merged issue: when it first merged, how many builder runs it took,
    # and how long from filing to merge (median)
    mq = "SELECT a.target AS id, MIN(a.ts) AS mts FROM activity a WHERE a.verb IN ('ci.merged', 'merge.done', 'pr.merged') GROUP BY a.target"
    first = db_query(db, "SELECT COUNT(*) AS n FROM (" ++ mq ++ ") m WHERE (SELECT COUNT(*) FROM run r WHERE r.issue_id = m.id) = 1", [])
    resolved = db_query(db, "SELECT COUNT(*) AS n FROM (" ++ mq ++ ") m", [])
    cyc = db_query(db, "SELECT (m.mts - i.created_at) / 60000 AS d FROM (" ++ mq ++ ") m JOIN issue i ON i.id = m.id ORDER BY d", [])
    failed = db_query(db, "SELECT COUNT(*) AS n FROM issue WHERE status = 'Failed'", [])
    nres = if (length(resolved) == 0) { 0 } else { map_get(hd(resolved), "n") }
    nfirst = if (length(first) == 0) { 0 } else { map_get(hd(first), "n") }
    nfail = if (length(failed) == 0) { 0 } else { map_get(hd(failed), "n") }
    median = if (length(cyc) == 0) { 0 } else { map_get(Std.at(cyc, length(cyc) / 2), "d") }
    %{merged_by_o: by_o, merged_by_human: by_human, merges: merges,
      resolved_issues: nres,
      first_attempt_pct: (if (nres > 0) { (100 * nfirst) / nres } else { 0 }),
      runs_per_resolved_x10: (if (nres > 0) { (10 * runs) / nres } else { 0 }),
      merge_rate_pct: (if (nres + nfail > 0) { (100 * nres) / (nres + nfail) } else { 0 }),
      median_cycle_minutes: median,
      autonomy_pct: (if (merges > 0) { (100 * by_o) / merges } else { 0 }),
      escaped: escaped, escaped_pct: (if (merges > 0) { (100 * escaped) / merges } else { 0 }),
      human_touches: touches, touches_per_merge_x10: (if (merges > 0) { (10 * touches) / merges } else { 0 }),
      caught_before_merge: caught, builder_runs: runs, spend_cents: cents,
      cents_per_merge: (if (merges > 0) { cents / merges } else { 0 })}
}

