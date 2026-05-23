#!/bin/sh
# Bring up O v4's dev environment as proper background processes:
# swarmd on :4100 + Vite on :5173, each under a watchdog loop that
# auto-restarts on crash. Both survive this shell session.
#
# Idempotent: re-running leaves healthy processes alone.
#
#   make dev     # start (or no-op if already up)
#   make stop-dev
#   make logs
set -e

O_ROOT="${O_ROOT:-/Users/sky/o}"
SWARMD="${SWARMD:-$HOME/.local/bin/swarmd}"
DIR="$HOME/.o"
mkdir -p "$DIR"

note() { printf '  %s\n' "$1"; }

# start_watchdog <name> <port> <inline-shell-command>
start_watchdog() {
  name="$1"; port="$2"; cmd="$3"
  pidf="$DIR/$name.pid"
  logf="$DIR/$name.log"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    note "$name already running (pid $(cat "$pidf"))"
    return
  fi
  # clear any stale port holder so we restart cleanly
  lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
  sleep 0.3
  # watchdog: trap kills the whole process group on exit, so `kill <pid>`
  # tears down both this bash and the child cleanly.
  nohup bash -c "
    trap 'kill 0 2>/dev/null' EXIT
    while true; do
      $cmd
      echo \"[\$(date '+%H:%M:%S')] $name exited — restarting in 1s\"
      sleep 1
    done
  " > "$logf" 2>&1 &
  echo $! > "$pidf"
  note "$name started (pid $(cat "$pidf"))"
}

echo "starting O v4 dev environment..."
start_watchdog daemon 4100 "'$SWARMD'"
start_watchdog ui     5173 "cd '$O_ROOT/ui' && npm run dev"

# wait briefly for both ports to come up
for i in $(seq 1 40); do
  lsof -iTCP:4100 -sTCP:LISTEN >/dev/null 2>&1 \
    && lsof -iTCP:5173 -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 0.3
done

echo
note "swarmd     http://localhost:4100   (api)"
note "React UI   http://localhost:5173   (open this)"
note "logs       tail -f $DIR/daemon.log    /    tail -f $DIR/ui.log    (or 'make logs')"
note "stop       make stop-dev"
echo

[ -n "$O_NO_OPEN" ] || open http://localhost:5173 2>/dev/null || true
