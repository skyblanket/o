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

    port0 = resolve_port()
    holder = instance_holder(dbpath)
    if (string_length(holder) > 0) {
        # One daemon per DB: two orchestrators on one DB re-dispatch the same
        # issues and fight over its rows.
        what = string_trim(elem(shell("tr '\\0' ' ' < /proc/" ++ holder ++ "/cmdline 2>/dev/null"), 1))
        print(f"FATAL: another O daemon (pid {holder}: {what}) is already running on {dbpath}; stop it first.")
    } else { if (port_in_use(port0) == 'true') {
        print(f"FATAL: port {port0} already answers /api/health; another daemon is on it. Set O_PORT or stop it.")
    } else {
    db = db_open(dbpath)
    if (db < 0) {
        print(f"FATAL: could not open control-plane database at {dbpath}")
    } else {
        register('idgen', spawn(idgen_loop(1)))
        Schema.migrate(db)
        # The port is resolved BEFORE the orchestrator starts so the tick loop
        # can hand a reflection worker the daemon's own base URL (it files
        # improvement issues back through the REST API on 127.0.0.1:{port}).
        port = port0
        Orchestrator.start(dbpath, port)

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
    }}
}

# The pid of a live O daemon holding this DB's lock file (<db>.pid), or "".
# This process's own pid is $PPID of the shell it spawns; it takes the lock
# when nobody live holds it.
fun instance_holder(dbpath) {
    me = string_trim(elem(shell("echo $PPID"), 1))
    lock = dbpath ++ ".pid"
    held = if (file_exists(lock) == 'true') { string_trim(file_read(lock)) } else { "" }
    # live = that pid is a swarmd that still has this DB open. A reused pid
    # (an sqlite3 on this DB, another swarmd on another DB) does not count,
    # nor does an orphaned child of the old daemon that inherited its handle.
    # (no `exit` in a shell() command: the runtime then waits ~2 min for it)
    probe = "h=" ++ Orchestrator.sq(held) ++ "; case \"$h\" in ''|*[!0-9]*) false ;; *) tr '\\0' ' ' < /proc/$h/cmdline 2>/dev/null | grep -q swarmd && p=$(realpath -m " ++ Orchestrator.sq(dbpath) ++ ") && ls -l /proc/$h/fd 2>/dev/null | grep -qF -- \" $p\" ;; esac"
    live = string_length(held) > 0 && held != me && elem(shell(probe), 0) == 0
    if (live) { held } else {
        _w = file_write(lock, me ++ "\n")
        ""
    }
}

fun port_in_use(port) {
    if (elem(shell(f"curl --noproxy '*' -s -f -m 2 -o /dev/null http://127.0.0.1:{port}/api/health"), 0) == 0) { 'true' } else { 'false' }
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
