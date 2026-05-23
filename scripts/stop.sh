#!/bin/sh
# Tear down the dev environment started by scripts/dev.sh.
DIR="$HOME/.o"
for name in daemon ui; do
  pidf="$DIR/$name.pid"
  if [ -f "$pidf" ]; then
    pid=$(cat "$pidf")
    if kill "$pid" 2>/dev/null; then
      printf '  stopped %-7s (pid %s)\n' "$name" "$pid"
    fi
    rm -f "$pidf"
  fi
done
# safety net — anything still holding the ports
lsof -tiTCP:4100 -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
lsof -tiTCP:5173 -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
echo "  done."
