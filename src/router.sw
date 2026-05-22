# ============================================================
# O v4 — router.sw  (HTTP request loop + REST routing)
# ============================================================
#
# serve/1 owns the daemon's request loop: it receives
# {'http_request', ...} messages from the swarmrt HTTP server
# and dispatches them. Every response is JSON, with permissive
# CORS so the O-Docs UI (Tauri) can call the daemon directly.
#
# Routes:
#   GET  /                                  banner
#   GET  /api/health                        liveness
#   GET  /api/runs                          run history
#   GET  /api/orchestrator                  live scheduler snapshot
#   GET  /api/approvals                     pending approvals
#   POST /api/approvals/:id                 decide an approval
#   GET  /api/companies                     list companies
#   POST /api/companies                     create company (+ budget)
#   GET  /api/companies/:id                 get one company
#   POST /api/companies/:id                 update budget / status
#   GET  /api/companies/:id/issues          list a company's issues
#   POST /api/companies/:id/issues          create an issue
#   GET  /api/companies/:id/agents          list a company's agents
#   POST /api/companies/:id/agents          hire an agent (approval-gated)

module Router

import Store
import Orchestrator

export [serve]

# dbpath is threaded alongside db so the chat endpoint can hand a
# spawned chat_worker its own connection string (sqlite handles must
# not be shared across processes).
fun serve(db, dbpath) {
    receive {
        {'http_request', conn, method, path, _hdrs, body} ->
            dispatch(db, dbpath, conn, method, path, body)
            serve(db, dbpath)
    }
}

# ---- response helpers ----------------------------------------

# swarmrt's http_respond takes headers as ONE string — each line
# CRLF-terminated; the runtime appends the final blank line.
fun json_headers() {
    "Content-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\n"
}

fun respond(conn, status, body) {
    http_respond(conn, status, json_headers(), body)
}

fun err_json(msg) {
    json_encode(%{error: msg})
}

fun default_str(v, d) {
    if (v == nil) { d } else { v }
}

fun default_num(v, d) {
    if (v == nil) { d } else { v }
}

# Approval gate is off unless O_REQUIRE_APPROVALS is set.
fun approvals_required() {
    if (getenv("O_REQUIRE_APPROVALS") == nil) { 'false' } else { 'true' }
}

# Ask the orchestrator process for a live scheduling snapshot.
fun orch_snapshot(conn) {
    send(whereis('orchestrator'), {'snapshot', self()})
    receive {
        {'snapshot_reply', d} -> respond(conn, 200, json_encode(d))
    }
}

# ---- dispatch ------------------------------------------------

fun dispatch(db, dbpath, conn, method, path, body) {
    if (method == 'OPTIONS') {
        http_respond(conn, 204, json_headers(), "")
    } else {
        route(db, dbpath, conn, method, path, body)
    }
}

# POST /api/fs {path} — list the sub-folders of a directory so the
# UI can offer a folder picker (no more mistyped repo paths).
fun route_fs(conn, method, body) {
    if (method == 'POST') {
        data = json_decode(body)
        raw = map_get(data, "path")
        home = getenv("HOME")
        path = if (raw == nil) { home } else { if (string_length(raw) == 0) { home } else { raw } }
        listing = elem(shell(f"ls -1 -Ap '{path}' 2>/dev/null"), 1)
        gits = elem(shell(f"find '{path}' -mindepth 2 -maxdepth 2 -name .git 2>/dev/null"), 1)
        parent = string_trim(elem(shell(f"dirname '{path}'"), 1))
        respond(conn, 200, json_encode(%{path: path, parent: parent, listing: listing, gits: gits}))
    } else {
        respond(conn, 405, err_json("method not allowed"))
    }
}

fun route(db, dbpath, conn, method, path, body) {
    case path {
        "/" -> respond(conn, 200, json_encode(%{name: "O", version: "v4", service: "swarmd", ui: "the React app — cd ui && npm run dev"}))
        "/api/health" -> respond(conn, 200, json_encode(%{status: "ok", service: "o-v4", version: "v4"}))
        "/api/runs" -> respond(conn, 200, json_encode(Store.runs_all(db)))
        "/api/activity" -> respond(conn, 200, json_encode(Store.activity_recent(db)))
        "/api/orchestrator" -> orch_snapshot(conn)
        "/api/fs" -> route_fs(conn, method, body)
        "/api/approvals" -> route_approvals(db, conn, method)
        "/api/companies" -> route_companies(db, conn, method, body)
        p when string_starts_with(p, "/api/companies/") == 'true' -> route_company(db, conn, method, p, body)
        p when string_starts_with(p, "/api/approvals/") == 'true' -> decide_approval(db, conn, method, p, body)
        p when string_starts_with(p, "/api/runs/") == 'true' -> run_result(db, conn, p)
        p when string_starts_with(p, "/api/issues/") == 'true' -> route_issue(db, conn, method, p, body)
        p when string_starts_with(p, "/api/agents/") == 'true' -> route_agent(db, dbpath, conn, method, p, body)
        _ -> respond(conn, 404, err_json("no route for that path"))
    }
}

# Local wrapper so `spawn` targets a same-module function — sw codegen
# can't spawn a module-qualified call. The cross-module hop into
# Orchestrator is a plain call inside the spawned process.
fun spawn_chat(dbpath, aid, msg) {
    Orchestrator.chat_worker(dbpath, aid, msg)
}

# ---- /api/agents/:id/{chat,messages} — operator <-> agent chat ----
#
#   POST /api/agents/:id/chat       send the agent a message
#   GET  /api/agents/:id/messages   the chat transcript

fun route_agent(db, dbpath, conn, method, p, body) {
    rest = string_sub(p, 12, string_length(p) - 12)
    if (string_ends_with(rest, "/chat") == 'true') {
        aid = string_sub(rest, 0, string_length(rest) - 5)
        agent_chat(db, dbpath, conn, method, aid, body)
    } else {
        if (string_ends_with(rest, "/messages") == 'true') {
            aid = string_sub(rest, 0, string_length(rest) - 9)
            if (method == 'GET') {
                respond(conn, 200, json_encode(Store.messages_for(db, aid)))
            } else {
                respond(conn, 405, err_json("method not allowed"))
            }
        } else {
            respond(conn, 404, err_json("no route for that path"))
        }
    }
}

# POST a chat message: persist the operator turn, then spawn a
# chat_worker (so the slow LLM turn never blocks this loop). The
# agent's reply lands in the message table asynchronously; the
# dashboard's GET /messages poll surfaces it.
fun agent_chat(db, dbpath, conn, method, aid, body) {
    if (method != 'POST') {
        respond(conn, 405, err_json("method not allowed"))
    } else {
        if (string_length(body) == 0) {
            respond(conn, 400, err_json("request body required"))
        } else {
            data = json_decode(body)
            msg = map_get(data, "message")
            if (msg == nil) {
                respond(conn, 400, err_json("field 'message' is required"))
            } else {
                agent = Store.agent_row(db, aid)
                if (agent == nil) {
                    respond(conn, 404, err_json("agent not found"))
                } else {
                    _m = Store.message_create(db, aid, "operator", msg)
                    _w = spawn(spawn_chat(dbpath, aid, msg))
                    _l = Store.log_activity(db, map_get(agent, "company_id"), "operator", "agent.chat", aid)
                    respond(conn, 202, json_encode(%{status: "sent", agent_id: aid}))
                }
            }
        }
    }
}

# ---- /api/companies ------------------------------------------

fun route_companies(db, conn, method, body) {
    if (method == 'GET') {
        respond(conn, 200, json_encode(Store.companies(db)))
    } else {
        if (method == 'POST') {
            create_company(db, conn, body)
        } else {
            respond(conn, 405, err_json("method not allowed"))
        }
    }
}

fun create_company(db, conn, body) {
    if (string_length(body) == 0) {
        respond(conn, 400, err_json("request body required"))
    } else {
        data = json_decode(body)
        name = map_get(data, "name")
        if (name == nil) {
            respond(conn, 400, err_json("field 'name' is required"))
        } else {
            mission = default_str(map_get(data, "mission"), "")
            prefix = default_str(map_get(data, "issue_prefix"), "TASK")
            budget = default_num(map_get(data, "budget_monthly_cents"), 0)
            id = Store.company_create(db, name, mission, prefix, budget)
            _l = Store.log_activity(db, id, "operator", "company.create", id)
            respond(conn, 201, json_encode(Store.company_row(db, id)))
        }
    }
}

# ---- /api/companies/:id  (+ /issues, /agents) ----------------

fun route_company(db, conn, method, p, body) {
    rest = string_sub(p, 15, string_length(p) - 15)
    if (string_ends_with(rest, "/issues") == 'true') {
        cid = string_sub(rest, 0, string_length(rest) - 7)
        route_issues(db, conn, method, cid, body)
    } else {
        if (string_ends_with(rest, "/agents") == 'true') {
            acid = string_sub(rest, 0, string_length(rest) - 7)
            route_agents(db, conn, method, acid, body)
        } else {
            if (method == 'GET') {
                row = Store.company_row(db, rest)
                if (row == nil) {
                    respond(conn, 404, err_json("company not found"))
                } else {
                    respond(conn, 200, json_encode(row))
                }
            } else {
                if (method == 'POST') {
                    update_company(db, conn, rest, body)
                } else {
                    respond(conn, 405, err_json("method not allowed"))
                }
            }
        }
    }
}

# Update a company's budget and/or status (e.g. un-pause after a
# budget hard-stop). Only the fields present in the body change.
fun update_company(db, conn, id, body) {
    cur = Store.company_row(db, id)
    if (cur == nil) {
        respond(conn, 404, err_json("company not found"))
    } else {
        data = json_decode(body)
        budget = default_num(map_get(data, "budget_monthly_cents"), map_get(cur, "budget_monthly_cents"))
        status = default_str(map_get(data, "status"), map_get(cur, "status"))
        _u = Store.company_update(db, id, budget, status)
        respond(conn, 200, json_encode(Store.company_row(db, id)))
    }
}

# ---- issues --------------------------------------------------

fun route_issues(db, conn, method, cid, body) {
    if (method == 'GET') {
        respond(conn, 200, json_encode(Store.issues_for(db, cid)))
    } else {
        if (method == 'POST') {
            create_issue(db, conn, cid, body)
        } else {
            respond(conn, 405, err_json("method not allowed"))
        }
    }
}

fun create_issue(db, conn, cid, body) {
    if (string_length(body) == 0) {
        respond(conn, 400, err_json("request body required"))
    } else {
        data = json_decode(body)
        title = map_get(data, "title")
        if (title == nil) {
            respond(conn, 400, err_json("field 'title' is required"))
        } else {
            ibody = default_str(map_get(data, "body"), "")
            priority = default_str(map_get(data, "priority"), "medium")
            id = Store.issue_create(db, cid, title, ibody, priority)
            if (id == nil) {
                respond(conn, 404, err_json("company not found"))
            } else {
                _l = Store.log_activity(db, cid, "operator", "issue.create", id)
                respond(conn, 201, json_encode(Store.issue_row(db, id)))
            }
        }
    }
}

# ---- agents (hiring is approval-gated) -----------------------

fun route_agents(db, conn, method, cid, body) {
    if (method == 'GET') {
        respond(conn, 200, json_encode(Store.agents_for(db, cid)))
    } else {
        if (method == 'POST') {
            create_agent(db, conn, cid, body)
        } else {
            respond(conn, 405, err_json("method not allowed"))
        }
    }
}

fun create_agent(db, conn, cid, body) {
    if (string_length(body) == 0) {
        respond(conn, 400, err_json("request body required"))
    } else {
        data = json_decode(body)
        name = map_get(data, "name")
        if (name == nil) {
            respond(conn, 400, err_json("field 'name' is required"))
        } else {
            role = default_str(map_get(data, "role"), "generalist")
            runtime = default_str(map_get(data, "runtime"), "claude-code")
            model = default_str(map_get(data, "model"), "")
            repo = default_str(map_get(data, "repo"), "")
            if (approvals_required() == 'true') {
                payload = json_encode(%{company_id: cid, name: name, role: role, runtime: runtime, model: model, repo: repo})
                aid = Store.approval_create(db, cid, "agent.hire", payload)
                _l = Store.log_activity(db, cid, "operator", "approval.requested", aid)
                respond(conn, 202, json_encode(%{status: "pending_approval", action: "agent.hire", approval_id: aid}))
            } else {
                id = Store.agent_create(db, cid, name, role, runtime, model, repo)
                _l = Store.log_activity(db, cid, "operator", "agent.hire", id)
                respond(conn, 201, json_encode(Store.agent_row(db, id)))
            }
        }
    }
}

# ---- approvals (governance gate) -----------------------------

fun route_approvals(db, conn, method) {
    if (method == 'GET') {
        respond(conn, 200, json_encode(Store.approvals_pending(db)))
    } else {
        respond(conn, 405, err_json("method not allowed"))
    }
}

fun decide_approval(db, conn, method, p, body) {
    aid = string_sub(p, 15, string_length(p) - 15)
    if (method == 'POST') {
        appr = Store.approval_row(db, aid)
        if (appr == nil) {
            respond(conn, 404, err_json("approval not found"))
        } else {
            data = json_decode(body)
            decision = default_str(map_get(data, "decision"), "")
            if (decision == "approve") {
                _x = execute_approval(db, appr)
                _s = Store.approval_set(db, aid, "approved")
                _l = Store.log_activity(db, map_get(appr, "company_id"), "operator", "approval.approved", aid)
                respond(conn, 200, json_encode(%{id: aid, status: "approved"}))
            } else {
                _s = Store.approval_set(db, aid, "rejected")
                _l = Store.log_activity(db, map_get(appr, "company_id"), "operator", "approval.rejected", aid)
                respond(conn, 200, json_encode(%{id: aid, status: "rejected"}))
            }
        }
    } else {
        respond(conn, 405, err_json("method not allowed"))
    }
}

# GET/POST /api/issues/:id — fetch or update a single issue. POST
# changes the operator-editable fields: status, priority, assignee.
fun route_issue(db, conn, method, p, body) {
    id = string_sub(p, 12, string_length(p) - 12)
    cur = Store.issue_row(db, id)
    if (cur == nil) {
        respond(conn, 404, err_json("issue not found"))
    } else {
        if (method == 'GET') {
            respond(conn, 200, json_encode(cur))
        } else {
            if (method == 'POST') {
                data = json_decode(body)
                status = default_str(map_get(data, "status"), map_get(cur, "status"))
                priority = default_str(map_get(data, "priority"), map_get(cur, "priority"))
                assignee = default_str(map_get(data, "assignee_agent_id"), map_get(cur, "assignee_agent_id"))
                _u = Store.issue_update(db, id, status, priority, assignee)
                _l = Store.log_activity(db, map_get(cur, "company_id"), "operator", "issue.update", id)
                respond(conn, 200, json_encode(Store.issue_row(db, id)))
            } else {
                respond(conn, 405, err_json("method not allowed"))
            }
        }
    }
}

# GET /api/runs/:id/result — the raw result.json a run produced in
# its workspace (claude-code runs); lets the UI show what an agent did.
fun run_result(db, conn, p) {
    rest = string_sub(p, 10, string_length(p) - 10)
    if (string_ends_with(rest, "/result") == 'true') {
        rid = string_sub(rest, 0, string_length(rest) - 7)
        run = Store.run_row(db, rid)
        if (run == nil) {
            respond(conn, 404, err_json("run not found"))
        } else {
            ws = map_get(run, "workspace_path")
            rpath = f"{ws}/result.json"
            if (file_exists(rpath) == 'true') {
                respond(conn, 200, json_encode(%{workspace: ws, result: file_read(rpath)}))
            } else {
                respond(conn, 200, json_encode(%{workspace: ws, result: ""}))
            }
        }
    } else {
        respond(conn, 404, err_json("not found"))
    }
}

# Carry out the governed action once approved.
fun execute_approval(db, appr) {
    if (map_get(appr, "action") == "agent.hire") {
        pl = json_decode(map_get(appr, "payload"))
        Store.agent_create(db, map_get(pl, "company_id"), map_get(pl, "name"), map_get(pl, "role"), map_get(pl, "runtime"), map_get(pl, "model"), default_str(map_get(pl, "repo"), ""))
    } else {
        ""
    }
}
