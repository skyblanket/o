#!/bin/sh
# Upgrade a running O without cutting its work off.
#
#   scripts/upgrade.sh NEW_SWARMD
#
# Turns drain on (nothing new starts), waits until nothing is in flight
# (builders, verifies, CI waits, gates), stops the daemon, swaps the binary
# (the old one is kept as <bin>.prev), starts it again, waits for health and
# turns drain off. If work is still in flight after O_UPGRADE_WAIT_S, it gives
# up, turns drain off and changes nothing.
#
# Env:
#   O_DB              the daemon's database (default ~/.o/o.db); <db>.pid names the daemon
#   O_PORT            its port (default 4100)
#   O_BIN             the binary to replace (default: what the daemon is running)
#   O_START           shell command that starts the daemon again, in the background
#   O_SERVICE         or: a systemd unit to restart instead (e.g. "o")
#   O_API_TOKEN       sent as a Bearer token when set
#   O_UPGRADE_WAIT_S  how long to wait for in-flight work (default 7200)
set -eu
new="${1:-}"
[ -n "$new" ] && [ -x "$new" ] || { echo "upgrade: usage: scripts/upgrade.sh NEW_SWARMD (an executable)"; exit 2; }
[ -n "${O_START:-}${O_SERVICE:-}" ] || { echo "upgrade: set O_START (a start command) or O_SERVICE (a systemd unit)"; exit 2; }
db="${O_DB:-$HOME/.o/o.db}"
base="http://127.0.0.1:${O_PORT:-4100}"
api() {
  if [ -n "${O_API_TOKEN:-}" ]; then curl -s -m 10 -H 'Content-Type: application/json' -H "Authorization: Bearer $O_API_TOKEN" "$@"
  else curl -s -m 10 -H 'Content-Type: application/json' "$@"; fi
}
in_flight() { api "$base/api/orchestrator" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("running", -1))
except Exception: print(-1)'; }
drain() { api -X POST "$base/api/orchestrator/drain" -d "{\"on\":$1}" >/dev/null; }

pid="$(cat "$db.pid" 2>/dev/null || true)"
[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || { echo "upgrade: no daemon is running for $db"; exit 2; }
bin="${O_BIN:-$(readlink "/proc/$pid/exe")}"

drain true
end=$(( $(date +%s) + ${O_UPGRADE_WAIT_S:-7200} ))
n="$(in_flight)"
while [ "$n" != "0" ]; do
  if [ "$(date +%s)" -ge "$end" ]; then
    drain false
    echo "upgrade: $n run(s) still in flight; gave up and changed nothing"
    exit 1
  fi
  sleep 5
  n="$(in_flight)"
done

if [ -n "${O_SERVICE:-}" ]; then
  cp "$bin" "$bin.prev" && cp "$new" "$bin.new" && mv "$bin.new" "$bin"
  systemctl restart "$O_SERVICE"
else
  kill "$pid"
  for _i in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid"
  cp "$bin" "$bin.prev" && cp "$new" "$bin.new" && mv "$bin.new" "$bin"
  sh -c "$O_START"
fi
for _i in $(seq 1 120); do api "$base/api/health" | grep -q '"ok"' && break; sleep 0.5; done
api "$base/api/health" | grep -q '"ok"' || { echo "upgrade: the new daemon is not answering on $base (old binary kept as $bin.prev)"; exit 1; }
drain false
echo "upgrade: done; nothing was in flight at the swap (old binary kept as $bin.prev)"
