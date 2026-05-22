# ============================================================
# O v4 — router.sw  (HTTP request loop + REST routing)
# ============================================================
#
# serve/1 owns the daemon's request loop: it receives
# {'http_request', ...} messages from the swarmrt HTTP server
# and dispatches them. Every response is JSON, with permissive
# CORS so the O-Docs UI (Tauri) can call the daemon directly.
#
# P0 routes:
#   GET  /                                  banner
#   GET  /api/health                        liveness
#   GET  /api/companies                     list companies
#   POST /api/companies                     create company
#   GET  /api/companies/:id                 get one company
#   GET  /api/companies/:id/issues          list a company's issues
#   POST /api/companies/:id/issues          create an issue

module Router

import Store

export [serve]

fun serve(db) {
    receive {
        {'http_request', conn, method, path, _hdrs, body} ->
            dispatch(db, conn, method, path, body)
            serve(db)
    }
}

# ---- response helpers ----------------------------------------

fun json_headers() {
    ["Content-Type: application/json", "Access-Control-Allow-Origin: *", "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS", "Access-Control-Allow-Headers: Content-Type, Authorization"]
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

# Ask the orchestrator process for a live scheduling snapshot.
fun orch_snapshot(conn) {
    send(whereis('orchestrator'), {'snapshot', self()})
    receive {
        {'snapshot_reply', d} -> respond(conn, 200, json_encode(d))
    }
}

# ---- dispatch ------------------------------------------------

fun dispatch(db, conn, method, path, body) {
    if (method == 'OPTIONS') {
        http_respond(conn, 204, json_headers(), "")
    } else {
        route(db, conn, method, path, body)
    }
}

fun route(db, conn, method, path, body) {
    case path {
        "/" -> respond(conn, 200, json_encode(%{name: "O", version: "v4", service: "swarmd"}))
        "/api/health" -> respond(conn, 200, json_encode(%{status: "ok", service: "o-v4", version: "v4"}))
        "/api/runs" -> respond(conn, 200, json_encode(Store.runs_all(db)))
        "/api/orchestrator" -> orch_snapshot(conn)
        "/api/companies" -> route_companies(db, conn, method, body)
        p when string_starts_with(p, "/api/companies/") == 'true' -> route_company(db, conn, method, p, body)
        _ -> respond(conn, 404, err_json("no route for that path"))
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
            id = Store.company_create(db, name, mission, prefix)
            _log = Store.log_activity(db, id, "operator", "company.create", id)
            respond(conn, 201, json_encode(Store.company_row(db, id)))
        }
    }
}

# ---- /api/companies/:id  and  /api/companies/:id/issues ------

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
                respond(conn, 405, err_json("method not allowed"))
            }
        }
    }
}

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
            id = Store.agent_create(db, cid, name, role, runtime, model)
            _l = Store.log_activity(db, cid, "operator", "agent.hire", id)
            respond(conn, 201, json_encode(Store.agent_row(db, id)))
        }
    }
}

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
                _log = Store.log_activity(db, cid, "operator", "issue.create", id)
                respond(conn, 201, json_encode(Store.issue_row(db, id)))
            }
        }
    }
}
