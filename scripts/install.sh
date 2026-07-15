#!/bin/sh
# O v4 installer — builds swarmd from source and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/skyblanket/o/main/scripts/install.sh | sh
#
# O v4 compiles with the swarmrt toolchain (`swc`). If swarmrt is not
# already present this script clones and builds it alongside O.
set -e

REPO_O="https://github.com/skyblanket/o"
REPO_SWARMRT="https://github.com/skyblanket/swarmrt"
ROOT="${O_INSTALL_ROOT:-$HOME/.o-src}"
PREFIX="${PREFIX:-$HOME/.local}"

say() { printf '\033[35m[o]\033[0m %s\n' "$1"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required"; exit 1; }; }

need git
need make
need cc

mkdir -p "$ROOT"

# --- swarmrt (build toolchain) -------------------------------------
if [ -n "$SWARMRT" ] && [ -x "$SWARMRT/bin/swc" ]; then
  say "using swarmrt at $SWARMRT"
else
  if [ ! -d "$ROOT/swarmrt" ]; then
    say "cloning swarmrt..."
    git clone --depth 1 "$REPO_SWARMRT" "$ROOT/swarmrt"
  fi
  say "building swarmrt..."
  ( cd "$ROOT/swarmrt" && make >/dev/null )
  SWARMRT="$ROOT/swarmrt"
fi

# --- O v4 ----------------------------------------------------------
if [ ! -d "$ROOT/o" ]; then
  say "cloning O..."
  git clone --depth 1 "$REPO_O" "$ROOT/o"
else
  ( cd "$ROOT/o" && git pull --ff-only >/dev/null 2>&1 || true )
fi

say "building swarmd..."
( cd "$ROOT/o" && make SWARMRT="$SWARMRT" >/dev/null )

say "installing..."
( cd "$ROOT/o" && make install PREFIX="$PREFIX" >/dev/null )

say "done."
echo
echo "  swarmd installed to $PREFIX/bin/swarmd"
echo "  make sure $PREFIX/bin is on your PATH, then:"
echo
echo "    swarmd                       # start the daemon (HTTP API on :4100)"
echo "    make dev                     # daemon + web UI (http://localhost:5173)"
echo
