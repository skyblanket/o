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
    dbpath = f"{dir}/o.db"

    db = db_open(dbpath)
    if (db < 0) {
        print(f"FATAL: could not open control-plane database at {dbpath}")
    } else {
        register('idgen', spawn(idgen_loop(1)))
        Schema.migrate(db)
        Orchestrator.start(dbpath)

        port = 4100
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
