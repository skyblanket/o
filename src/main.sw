# ============================================================
# O v4 — main.sw  (the `swarmd` daemon entrypoint)
# ============================================================
#
# Boots the orchestrator control plane:
#   1. opens the SQLite control-plane database (~/.o/o.db)
#   2. starts the `idgen` process (monotonic unique ids)
#   3. migrates the schema
#   4. starts the HTTP server and enters the request loop
#
# P0 scope: the spine — database + HTTP + REST CRUD for the
# core entities. The orchestration tick loop (P1) and agent
# layer (P2) build on top of this.

module Main

import Schema
import Orchestrator
import Router

export [main]

# idgen — a tiny process that hands out unique ids. Registered as
# 'idgen'; Store.next_id/1 talks to it. The monotonic counter keeps
# ids unique within a run; the timestamp suffix keeps them distinct
# across daemon restarts.
fun idgen_loop(n) {
    receive {
        {'gen', from, prefix} ->
            ts = timestamp()
            send(from, {'id', f"{prefix}_{n}_{ts}"})
            idgen_loop(n + 1)
    }
}

fun main() {
    home = getenv("HOME")
    dir = f"{home}/.o"
    _mk = shell(f"mkdir -p {dir}/workspaces")
    # O_DB env override lets a second instance run on its own
    # control plane instead of sharing ~/.o/o.db.
    db_env = getenv("O_DB")
    dbpath = if (db_env == nil) { f"{dir}/o.db" } else { db_env }

    db = db_open(dbpath)
    if (db < 0) {
        print(f"FATAL: could not open control-plane database at {dbpath}")
    } else {
        register('idgen', spawn(idgen_loop(1)))
        Schema.migrate(db)
        Orchestrator.start(dbpath)

        port = resolve_port()
        http_listen(port)
        print("")
        print("  O v4 - agent-company orchestrator")
        print("  ---------------------------------")
        print(f"  daemon     swarmd, listening on 127.0.0.1:{port}")
        print(f"  dashboard  http://127.0.0.1:{port}")
        print(f"  api        http://127.0.0.1:{port}/api/health")
        print(f"  database   {dbpath}")
        print("  ready.")
        print("")

        Router.serve(db, dbpath)
    }
}

# HTTP port — O_PORT env override, default 4100. Lets a second
# instance run alongside one already holding the default port.
fun resolve_port() {
    p = getenv("O_PORT")
    if (p == nil) {
        4100
    } else {
        n = parse_port_digits(p, 0, 0)
        if (n < 1) { 4100 } else { n }
    }
}

fun parse_port_digits(s, i, acc) {
    if (i >= string_length(s)) {
        acc
    } else {
        ch = string_sub(s, i, 1)
        d = if (ch == "0") { 0 } else { if (ch == "1") { 1 }
            else { if (ch == "2") { 2 } else { if (ch == "3") { 3 }
            else { if (ch == "4") { 4 } else { if (ch == "5") { 5 }
            else { if (ch == "6") { 6 } else { if (ch == "7") { 7 }
            else { if (ch == "8") { 8 } else { if (ch == "9") { 9 }
            else { 0 - 1 }}}}}}}}}}
        if (d < 0) { acc } else { parse_port_digits(s, i + 1, acc * 10 + d) }
    }
}
