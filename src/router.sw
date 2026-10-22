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
#   GET  /api/companies/:id/personas        list a company's personas
#   POST /api/companies/:id/personas        add a persona
#   POST /api/personas/:id                  edit / enable / disable a persona
#   GET  /api/companies/:id/persona_runs    persona run history + reports
#   POST /api/companies/:id/persona_reports a running persona files a finding

module Router

import Store
import Orchestrator

export [serve]

# dbpath is threaded alongside db so the chat endpoint can hand a
# spawned chat_worker its own connection string (sqlite handles must
# not be shared across processes).
fun serve(db, dbpath) {
    receive {
        {'http_request', conn, method, path, hdrs, body} ->
            dispatch(db, dbpath, conn, method, path, hdrs, body)
            serve(db, dbpath)
    }
}

# ---- response helpers ----------------------------------------

# swarmrt's http_respond takes headers as ONE string — each line
# CRLF-terminated; the runtime appends the final blank line.
fun json_headers() {
    "Content-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization, Idempotency-Key\r\n"
}

# conn is the request's connection, or {'idem', conn, key, db} when the write
# carried an Idempotency-Key: a 2xx answer is then stored for replay.
fun respond(conn, status, body) {
    case conn {
        {'idem', c, k, db} ->
            _s = if (status >= 200 && status < 300) { Store.idem_put(db, k, status, body) } else { "" }
            http_respond(c, status, json_headers(), body)
        _ -> http_respond(conn, status, json_headers(), body)
    }
}

# A write with an Idempotency-Key header that was already answered (2xx, in
# the last 24h) gets the same answer again and writes nothing: a client that
# retries after a dropped response can't file the same thing twice. Keys are
# scoped to the method and path.
fun idem_route(db, dbpath, conn, method, path, hdrs, body) {
    key = hdr(hdrs, "idempotency-key")
    if (string_length(key) == 0) { route(db, dbpath, conn, method, path, body) } else {
        k = to_string(method) ++ " " ++ path ++ " " ++ key
        prev = Store.idem_get(db, k)
        if (prev == nil) { route(db, dbpath, {'idem', conn, k, db}, method, path, body) }
        else { http_respond(conn, map_get(prev, "status"), json_headers(), map_get(prev, "body")) }
    }
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
# POST /api/orchestrator/drain {"on": true|false}: stop (or resume) new
# dispatch; in-flight runs finish. Token-guarded like every non-issue write.
fun route_drain(dbpath, conn, method, body) {
    if (method != 'POST') {
        respond(conn, 405, err_json("POST {\"on\": true|false}"))
    } else {
        d = json_decode(body)
        on = d != nil && map_get(d, "on") == 'true'
        _f = if (on) { file_write(dbpath ++ ".drain", "") } else { shell("rm -f '" ++ dbpath ++ ".drain'") }
        orch_snapshot(conn)
    }
}

fun orch_snapshot(conn) {
    send(whereis('orchestrator'), {'snapshot', self()})
    receive {
        {'snapshot_reply', d} -> respond(conn, 200, json_encode(d))
    }
}

# ---- dispatch ------------------------------------------------

# Write guards, in order:
#   OPTIONS — a CORS preflight is answered only for a loopback Origin, so a
#             random web page in the operator's browser can't get a JSON write
#             through (the UI and the feedback widget run on localhost).
#   415     — every write must be Content-Type: application/json. That forces
#             a browser preflight, closing the "simple request" (text/plain
#             form post) hole that skips CORS entirely.
#   401     — when O_API_TOKEN is set, company + agent + approval writes need
#             `Authorization: Bearer <token>`. Agent runs never see the token
#             (it is stripped from their env), so an agent cannot rewrite the
#             verify_cmd / protected_paths that gate its own merges. Filing
#             issues and feedback stays open: that is how reflection reports.
# O_PUBLIC_READONLY=1 (o#41), for exposing the UI through a tunnel: only GET
# routes answer. Every write (issue filing included, which is otherwise open
# without a token) and /api/fs are refused with 403.
fun public_readonly() { getenv("O_PUBLIC_READONLY") == "1" }

fun dispatch(db, dbpath, conn, method, path, hdrs, body) {
    if (public_readonly() && (string_starts_with(path, "/api/fs") == 'true' || (method != 'GET' && method != 'OPTIONS'))) {
        respond(conn, 403, err_json("this O is read-only (O_PUBLIC_READONLY=1)"))
    } else { if (method == 'OPTIONS') {
        if (loopback_origin(hdr(hdrs, "origin")) == 'true') {
            http_respond(conn, 204, json_headers(), "")
        } else {
            http_respond(conn, 403, "Content-Type: application/json\r\n", err_json("cross-origin request refused"))
        }
    } else {
        if (method == 'GET') {
            route(db, dbpath, conn, method, path, body)
        } else {
            if (string_starts_with(hdr(hdrs, "content-type"), "application/json") == 'false') {
                respond(conn, 415, err_json("writes require Content-Type: application/json"))
            } else {
                if (token_ok(path, hdrs) == 'false') {
                    respond(conn, 401, err_json("this write requires Authorization: Bearer $O_API_TOKEN"))
                } else {
                    idem_route(db, dbpath, conn, method, path, hdrs, body)
                }
            }
        }
    }}
}

# Header lookup (keys arrive lowercased); missing -> "".
fun hdr(hdrs, k) {
    v = if (hdrs == nil) { nil } else { map_get(hdrs, k) }
    if (v == nil) { "" } else { v }
}

# No Origin (curl, the reflection worker) or a loopback one.
fun loopback_origin(o) {
    if (string_length(o) == 0) { 'true' }
    else { if (string_starts_with(o, "http://localhost") == 'true') { 'true' }
    else { if (string_starts_with(o, "http://127.0.0.1") == 'true') { 'true' }
    else { 'false' }}}
}

# Writes that stay open even with a token set: filing issues and feedback.
fun open_write(path) {
    if (string_ends_with(path, "/issues") == 'true') { 'true' }
    else { if (string_ends_with(path, "/feedback") == 'true') { 'true' }
    else { if (string_ends_with(path, "/chat") == 'true') { 'true' }
    else { if (string_ends_with(path, "/persona_reports") == 'true') { 'true' }
    else { 'false' }}}}
}

fun token_ok(path, hdrs) {
    tok = getenv("O_API_TOKEN")
    if (tok == nil) {
        'true'
    } else {
        if (open_write(path) == 'true') {
            'true'
        } else {
            if (hdr(hdrs, "authorization") == "Bearer " ++ tok) { 'true' } else { 'false' }
        }
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

# POST /api/issues/:id/retry {model?} — another round for a Failed or Canceled
# issue: fresh attempts, the last failure appended to its body so the next
# builder starts from it, and optionally a stronger model to start on (rungs
# of O_MODEL_LADDER, recorded as operator escalations). Token-guarded.
fun route_retry(db, conn, method, p, body) {
    id = string_sub(p, 12, string_length(p) - 12 - 6)
    cur = Store.issue_row(db, id)
    st = if (cur == nil) { "" } else { default_str(map_get(cur, "status"), "") }
    if (method != 'POST') { respond(conn, 405, err_json("method not allowed")) }
    else { if (cur == nil) { respond(conn, 404, err_json("issue not found")) }
    else { if (st != "Failed" && st != "Canceled") { respond(conn, 409, err_json("only a Failed or Canceled issue can be retried (this one is " ++ st ++ ")")) }
    else {
    data = if (string_length(body) > 0) { json_decode(body) } else { nil }
    rounds = 1 + Store.retry_count(db, id)
    # Rounds are capped so one hard issue can't eat the budget in a loop of new
    # attempts; past the cap a person decides ({"force": true}) with the history
    # O posted when it stopped.
    if (rounds >= max_rounds() && (data == nil || map_get(data, "force") != 'true')) {
        respond(conn, 409, err_json("this issue has had " ++ to_string(rounds) ++ " rounds (O_MAX_ROUNDS=" ++ to_string(max_rounds()) ++ "); read what was tried and send {\"force\": true} to run another"))
    }
    else {
        model = if (data == nil) { "" } else { default_str(map_get(data, "model"), "") }
        _q = Orchestrator.requeue_round(db, id, model, "", "operator")
        respond(conn, 200, json_encode(Store.issue_row(db, id)))
    }}}}
}

# GET /api/companies/:id/maintainer: the merge gate's shared notes (as kept in
# the control plane), its current session and how many reviews it has done.
fun maintainer_info(db, conn, cid) {
    c = Store.company_row(db, cid)
    if (c == nil) { respond(conn, 404, err_json("no such company")) }
    else { respond(conn, 200, json_encode(%{notes: Store.notes_latest(db, cid), session: default_str(map_get(c, "maintainer_session"), ""), reviews: default_num(map_get(c, "maintainer_reviews"), 0)})) }
}

fun max_rounds() { Orchestrator.env_int("O_MAX_ROUNDS", 3) }


fun route(db, dbpath, conn, method, path, body) {
    case path {
        "/" -> respond(conn, 200, json_encode(%{name: "O", version: "v4", service: "swarmd", ui: "the React app — cd ui && npm run dev"}))
        "/api/health" -> respond(conn, 200, json_encode(%{status: "ok", service: "o-v4", version: "v4"}))
        "/api/runs" -> respond(conn, 200, json_encode(Store.runs_all(db)))
        "/api/activity" -> respond(conn, 200, json_encode(Store.activity_recent(db)))
        "/api/proof" -> respond(conn, 200, json_encode(Store.proof(db)))
        "/api/waiting" -> respond(conn, 200, json_encode(Orchestrator.waiting_list(db)))
        "/api/orchestrator" -> orch_snapshot(conn)
        "/api/orchestrator/drain" -> route_drain(dbpath, conn, method, body)
        "/api/fs" -> route_fs(conn, method, body)
        "/api/approvals" -> route_approvals(db, conn, method)
        "/api/companies" -> route_companies(db, conn, method, body)
        p when string_starts_with(p, "/api/companies/") == 'true' && string_ends_with(p, "/maintainer") == 'true' -> maintainer_info(db, conn, string_sub(p, 15, string_length(p) - 15 - 11))
        p when string_starts_with(p, "/api/companies/") == 'true' -> route_company(db, conn, method, p, body)
        p when string_starts_with(p, "/api/approvals/") == 'true' -> decide_approval(db, conn, method, p, body)
        p when string_starts_with(p, "/api/runs/") == 'true' -> run_result(db, conn, p)
        p when string_starts_with(p, "/api/issues/") == 'true' && string_ends_with(p, "/retry") == 'true' -> route_retry(db, conn, method, p, body)
        p when string_starts_with(p, "/api/issues/") == 'true' && string_ends_with(p, "/activity") == 'true' -> respond(conn, 200, json_encode(Store.activity_for_target(db, string_sub(p, 12, string_length(p) - 12 - 9))))
        p when string_starts_with(p, "/api/issues/") == 'true' -> route_issue(db, conn, method, p, body)
        p when string_starts_with(p, "/api/agents/") == 'true' -> route_agent(db, dbpath, conn, method, p, body)
        p when string_starts_with(p, "/api/personas/") == 'true' -> update_persona(db, conn, method, p, body)
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
            repo = default_str(map_get(data, "repo"), "")
            verr = validate_repo(repo)
            if (string_length(verr) > 0) {
                respond(conn, 400, err_json(verr))
            } else {
                mission = default_str(map_get(data, "mission"), "")
                prefix = default_str(map_get(data, "issue_prefix"), "TASK")
                budget = default_num(map_get(data, "budget_monthly_cents"), 0)
                verify_cmd = default_str(map_get(data, "verify_cmd"), "")
                protected_paths = default_str(map_get(data, "protected_paths"), "")
                budget_daily = default_num(map_get(data, "budget_daily_cents"), 0)
                ship = default_str(map_get(data, "ship"), "merge")
                gh = default_str(map_get(data, "github_repo"), "")
                ship_err = validate_ship(ship, gh)
                if (string_length(ship_err) > 0) {
                    respond(conn, 400, err_json(ship_err))
                } else {
                    id = Store.company_create(db, name, mission, prefix, budget, repo, verify_cmd, protected_paths, budget_daily)
                    _g = Store.company_set_github(db, id, gh, ship)
                    _l = Store.log_activity(db, id, "operator", "company.create", id)
                    respond(conn, 201, json_encode(Store.company_row(db, id)))
                }
            }
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
      if (string_ends_with(rest, "/feedback") == 'true') {
        fcid = string_sub(rest, 0, string_length(rest) - 9)
        route_feedback(db, conn, method, fcid, body)
      } else {
        if (string_ends_with(rest, "/agents") == 'true') {
            acid = string_sub(rest, 0, string_length(rest) - 7)
            route_agents(db, conn, method, acid, body)
        } else {
          if (string_ends_with(rest, "/personas") == 'true') {
            route_personas(db, conn, method, string_sub(rest, 0, string_length(rest) - 9), body)
          } else {
          if (string_ends_with(rest, "/persona_runs") == 'true') {
            prc = string_sub(rest, 0, string_length(rest) - 13)
            if (method == 'GET') { respond(conn, 200, json_encode(Store.persona_runs_for(db, prc))) } else { respond(conn, 405, err_json("method not allowed")) }
          } else {
          if (string_ends_with(rest, "/persona_reports") == 'true') {
            persona_report(db, conn, method, string_sub(rest, 0, string_length(rest) - 16), body)
          } else {
          if (string_ends_with(rest, "/board") == 'true') {
            respond(conn, 200, json_encode(Orchestrator.board(db, string_sub(rest, 0, string_length(rest) - 6))))
          } else {
          if (string_contains(rest, "/spend") == 'true') {
            parts = string_split(rest, "/spend")
            q = Std.last(parts)
            dq = if (string_contains(q, "days=") == 'true') { to_int(Std.last(string_split(q, "days="))) } else { nil }
            respond(conn, 200, json_encode(Orchestrator.spend_view(db, hd(parts), if (dq == nil) { 14 } else { dq })))
          } else {
          if (string_ends_with(rest, "/gate/rotate") == 'true') {
            gcid = string_sub(rest, 0, string_length(rest) - 12)
            if (method != 'POST') { respond(conn, 405, err_json("POST to rotate")) } else {
                _c = Store.company_clear_maintainer(db, gcid)
                _l = Store.log_activity(db, gcid, "operator", "gate.rotated", gcid)
                respond(conn, 200, json_encode(Orchestrator.gate_info(db, gcid)))
            }
          } else {
          if (string_ends_with(rest, "/gate") == 'true') {
            respond(conn, 200, json_encode(Orchestrator.gate_info(db, string_sub(rest, 0, string_length(rest) - 5))))
          } else {
          if (string_ends_with(rest, "/errors") == 'true') {
            ecid = string_sub(rest, 0, string_length(rest) - 7)
            data = if (string_length(body) > 0) { json_decode(body) } else { nil }
            if (method != 'POST') { respond(conn, 405, err_json("method not allowed")) }
            else { if (Store.company_row(db, ecid) == nil) { respond(conn, 404, err_json("company not found")) }
            else { if (data == nil) { respond(conn, 400, err_json("expected a JSON error event")) }
            else { respond(conn, 200, json_encode(Orchestrator.ingest_error(db, ecid, data))) }}}
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
          }}}}}}}}
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
        # Only validate the repo when the payload actually carries a "repo"
        # key. Otherwise a status/budget-only update would re-validate the
        # stored repo and 400 if that dir was since deleted — an unrelated
        # field must never be held hostage by a stale repo path.
        raw_repo = map_get(data, "repo")
        repo = if (raw_repo == nil) { map_get(cur, "repo") } else { raw_repo }
        verr = if (raw_repo == nil) { "" } else { validate_repo(repo) }
        if (string_length(verr) > 0) {
            respond(conn, 400, err_json(verr))
        } else {
            budget = default_num(map_get(data, "budget_monthly_cents"), map_get(cur, "budget_monthly_cents"))
            status = default_str(map_get(data, "status"), map_get(cur, "status"))
            verify_cmd = default_str(map_get(data, "verify_cmd"), map_get(cur, "verify_cmd"))
            protected_paths = default_str(map_get(data, "protected_paths"), map_get(cur, "protected_paths"))
            budget_daily = default_num(map_get(data, "budget_daily_cents"), map_get(cur, "budget_daily_cents"))
            ship = default_str(map_get(data, "ship"), default_str(map_get(cur, "ship"), "merge"))
            gh = default_str(map_get(data, "github_repo"), default_str(map_get(cur, "github_repo"), ""))
            ship_err = validate_ship(ship, gh)
            if (string_length(ship_err) > 0) {
                respond(conn, 400, err_json(ship_err))
            } else {
                _u = Store.company_update(db, id, budget, status, repo, verify_cmd, protected_paths, budget_daily)
                _g = Store.company_set_github(db, id, gh, ship)
                _pp = Store.company_set_persona(db, id, default_num(map_get(data, "persona_daily_cents"), map_get(cur, "persona_daily_cents")), default_num(map_get(data, "personas_per_day"), map_get(cur, "personas_per_day")))
                respond(conn, 200, json_encode(Store.company_row(db, id)))
            }
        }
    }
}

# ---- personas ------------------------------------------------
#
# A persona is a simulated user: a role, a realistic goal, where they start
# (usually the README) and what "done" looks like. The daily pass hands one a
# clean checkout and lets it try; it files what blocked it through
# /persona_reports. Adding or editing a persona is an operator write (token).

fun route_personas(db, conn, method, cid, body) {
    if (method == 'GET') {
        respond(conn, 200, json_encode(Store.personas_for(db, cid)))
    } else {
        if (method == 'POST') {
            create_persona(db, conn, cid, body)
        } else {
            respond(conn, 405, err_json("method not allowed"))
        }
    }
}

fun create_persona(db, conn, cid, body) {
    if (Store.company_row(db, cid) == nil) {
        respond(conn, 404, err_json("company not found"))
    } else {
        data = json_decode(body)
        name = map_get(data, "name")
        goal = map_get(data, "goal")
        if (name == nil || goal == nil) {
            respond(conn, 400, err_json("fields 'name' and 'goal' are required"))
        } else {
            id = Store.persona_create(db, cid, name, default_str(map_get(data, "role"), ""), goal, default_str(map_get(data, "start"), "README.md"), default_str(map_get(data, "done_when"), ""), default_str(map_get(data, "model"), ""))
            _l = Store.log_activity(db, cid, "operator", "persona.create", id)
            respond(conn, 201, json_encode(Store.persona_row(db, id)))
        }
    }
}

fun update_persona(db, conn, method, p, body) {
    id = string_sub(p, 14, string_length(p) - 14)
    cur = Store.persona_row(db, id)
    if (cur == nil) {
        respond(conn, 404, err_json("persona not found"))
    } else {
        if (method != 'POST') {
            respond(conn, 405, err_json("method not allowed"))
        } else {
            data = json_decode(body)
            en_raw = map_get(data, "enabled")
            enabled = if (en_raw == nil) { map_get(cur, "enabled") } else { if (en_raw == 'false' || en_raw == 0) { 0 } else { 1 } }
            _u = Store.persona_set(db, id, default_str(map_get(data, "name"), map_get(cur, "name")), default_str(map_get(data, "role"), map_get(cur, "role")), default_str(map_get(data, "goal"), map_get(cur, "goal")), default_str(map_get(data, "start"), map_get(cur, "start")), default_str(map_get(data, "done_when"), map_get(cur, "done_when")), default_str(map_get(data, "model"), map_get(cur, "model")), enabled)
            respond(conn, 200, json_encode(Store.persona_row(db, id)))
        }
    }
}

# POST /api/companies/:id/persona_reports — open (the persona has no token),
# but only a persona run that is still in flight for this company may report,
# and every report must carry a repro: no steps or no verbatim `actual` is a
# 400. The reply says nothing about other reports or the board: a persona
# never learns what anyone else found.
fun persona_report(db, conn, method, cid, body) {
    if (method != 'POST') {
        respond(conn, 405, err_json("method not allowed"))
    } else {
        data = json_decode(body)
        run_id = default_str(map_get(data, "run_id"), "")
        run = Store.persona_run_row(db, run_id)
        rerr = persona_report_error(run, cid, data)
        if (string_length(rerr) > 0) {
            respond(conn, 400, err_json(rerr))
        } else {
            rep = %{severity: map_get(data, "severity"), title: string_truncate(map_get(data, "title"), 200), doc_section: string_truncate(default_str(map_get(data, "doc_section"), ""), 200), steps: string_truncate(map_get(data, "steps"), 4000), expected: string_truncate(default_str(map_get(data, "expected"), ""), 2000), actual: string_truncate(map_get(data, "actual"), 4000), env: string_truncate(default_str(map_get(data, "env"), ""), 500)}
            n = Store.persona_run_add_report(db, run_id, rep)
            respond(conn, 201, json_encode(%{status: "recorded", reports: n}))
        }
    }
}

fun blank(v) {
    if (v == nil) { 'true' } else { if (string_length(string_trim(v)) == 0) { 'true' } else { 'false' } }
}

fun persona_report_error(run, cid, data) {
    sev = default_str(map_get(data, "severity"), "")
    if (run == nil) { "unknown run_id" }
    else { if (map_get(run, "company_id") != cid) { "unknown run_id" }
    else { if (map_get(run, "ended_at") != 0) { "this persona run has already finished" }
    else { if (sev != "blocked" && sev != "wrong" && sev != "friction") { "severity must be blocked, wrong or friction" }
    else { if (blank(map_get(data, "title")) == 'true') { "field 'title' is required" }
    else { if (blank(map_get(data, "steps")) == 'true' || blank(map_get(data, "actual")) == 'true') { "a report needs a repro: 'steps' and the verbatim 'actual' output" }
    else { "" }}}}}}
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
            # Only "reflect" is an honored self-origin over the API; any other
            # value (or absence) is operator-filed. A reflect issue routes
            # through the capped auto path with an EMPTY fingerprint (cap-only,
            # no dedup — distinct reflections are allowed) and is logged as
            # reflect.filed by the reflection actor.
            raw_origin = default_str(map_get(data, "origin"), "operator")
            if (raw_origin == "reflect") {
                id = Store.issue_create_auto(db, cid, title, ibody, priority, "reflect", "")
                if (id == nil) {
                    respond(conn, 429, err_json("reflection cap reached"))
                } else {
                    _l = Store.log_activity(db, cid, "reflection", "reflect.filed", id)
                    respond(conn, 201, json_encode(Store.issue_row(db, id)))
                }
            } else {
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
}

# ---- feedback (Vorflux-style visual annotation intake) -------
#
#   POST /api/companies/:id/feedback
#   Body: {"page_url","title"(opt),"annotations":[{selector,html,styles,instruction}...]}
#
# The embeddable widget (feedback/o-feedback.js) POSTs a batch of on-page
# annotations here. Each becomes a markdown section in ONE issue body, filed
# with origin='feedback' via issue_create_with_origin — DELIBERATELY not the
# capped auto/reflect path, so a human's feedback is never swallowed by the
# loop's self-file daily cap.

fun route_feedback(db, conn, method, cid, body) {
    if (method == 'POST') {
        create_feedback(db, conn, cid, body)
    } else {
        respond(conn, 405, err_json("method not allowed"))
    }
}

fun create_feedback(db, conn, cid, body) {
    if (string_length(body) == 0) {
        respond(conn, 400, err_json("request body required"))
    } else {
        data = json_decode(body)
        page_url = map_get(data, "page_url")
        anns = map_get(data, "annotations")
        if (page_url == nil) {
            respond(conn, 400, err_json("field 'page_url' is required"))
        } else {
            if (anns == nil) {
                respond(conn, 400, err_json("field 'annotations' must be a non-empty array"))
            } else {
                if (is_list(anns) == 'false') {
                    respond(conn, 400, err_json("field 'annotations' must be a non-empty array"))
                } else {
                    if (length(anns) == 0) {
                        respond(conn, 400, err_json("field 'annotations' must be a non-empty array"))
                    } else {
                        n = length(anns)
                        raw_title = map_get(data, "title")
                        title = if (raw_title == nil) { f"Feedback: {n} annotation(s) on {page_url}" } else { raw_title }
                        title2 = string_truncate(title, 200)
                        fbody = compose_feedback_body(page_url, n, anns)
                        id = Store.issue_create_with_origin(db, cid, title2, fbody, "medium", "feedback")
                        if (id == nil) {
                            respond(conn, 404, err_json("company not found"))
                        } else {
                            _l = Store.log_activity(db, cid, "feedback-widget", "feedback.filed", id)
                            respond(conn, 201, json_encode(Store.issue_row(db, id)))
                        }
                    }
                }
            }
        }
    }
}

# One markdown body: a header line naming the page + annotation count, then a
# section per annotation. Each html payload is truncated to ~2000 chars so a
# giant DOM subtree can't bloat the control plane.
fun compose_feedback_body(page_url, n, anns) {
    header = f"Visual feedback captured on {page_url} — {n} annotation(s).\n\n"
    header ++ fmt_annotations(anns, 1)
}

fun fmt_annotations(anns, idx) {
    if (length(anns) == 0) {
        ""
    } else {
        a = hd(anns)
        instruction = default_str(map_get(a, "instruction"), "(no instruction)")
        selector = default_str(map_get(a, "selector"), "(unknown selector)")
        styles = map_get(a, "styles")
        styles_str = if (styles == nil) { "{}" } else { json_encode(styles) }
        html = default_str(map_get(a, "html"), "")
        html_trunc = string_truncate(html, 2000)
        sec = f"### Annotation {idx} — {instruction}\n\n" ++ f"- selector: `{selector}`\n\n" ++ "- styles:\n\n```json\n" ++ styles_str ++ "\n```\n\n" ++ "- html:\n\n```html\n" ++ html_trunc ++ "\n```\n\n"
        sec ++ fmt_annotations(tl(anns), idx + 1)
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

# Return "" if the repo path is empty or valid; an error message
# otherwise. Catches the typo class up front so hiring fails loudly,
# not silently in a retry loop.
# ship is "merge" or "pr"; PR mode talks to the GitHub REST API, which needs
# the repo spelled out as owner/name.
fun validate_ship(ship, gh) {
    if (ship != "merge" && ship != "pr") {
        "ship must be \"merge\" or \"pr\""
    } else {
        if (ship == "pr" && string_contains(gh, "/") == 'false') { "ship \"pr\" needs github_repo as \"owner/name\"" } else { "" }
    }
}

fun validate_repo(repo) {
    if (string_length(repo) == 0) {
        ""
    } else {
        if (file_exists(repo) == 'false') {
            f"repo path does not exist: {repo}"
        } else {
            if (file_exists(f"{repo}/.git") == 'false') {
                f"not a git repo (no .git): {repo}"
            } else {
                ""
            }
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
            repo = default_str(map_get(data, "repo"), "")
            verr = validate_repo(repo)
            if (string_length(verr) > 0) {
                respond(conn, 400, err_json(verr))
            } else {
                role = default_str(map_get(data, "role"), "generalist")
                runtime = default_str(map_get(data, "runtime"), "claude-code")
                model = default_str(map_get(data, "model"), "")
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
            # Once phase-3 cleanup removes the worktree, the artifacts live on in
            # $HOME/.o/archive/<run_id>/ — fall back to there so a merged/reverted/
            # failed run still surfaces its stream + logs.
            home = getenv("HOME")
            arc = f"{home}/.o/archive/{rid}"
            res = read_first(f"{ws}/result.json", f"{arc}/result.json")
            stream = read_first(f"{ws}/stream.jsonl", f"{arc}/stream.jsonl")
            errlog = read_first(f"{ws}/err.log", f"{arc}/err.log")
            respond(conn, 200, json_encode(%{workspace: ws, result: res, stream: stream, error: errlog, verify_state: default_str(map_get(run, "verify_state"), ""), verify_output: default_str(map_get(run, "verify_output"), ""), merge_sha: default_str(map_get(run, "merge_sha"), "")}))
        }
    } else {
        respond(conn, 404, err_json("not found"))
    }
}

# Read the first of two paths that exists, else "". Lets a run's artifacts be
# served from its live worktree, then from the post-cleanup archive.
fun read_first(a, b) {
    if (file_exists(a) == 'true') {
        file_read(a)
    } else {
        if (file_exists(b) == 'true') { file_read(b) } else { "" }
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
