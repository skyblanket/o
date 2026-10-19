#!/bin/sh
# Install O as an always-on service for the current user (Linux, systemd).
#
#   git clone https://github.com/skyblanket/o && cd o && deploy/install.sh
#
# Builds swarmrt (as a sibling checkout) and O, installs bin/swarmd into
# ~/.local/bin, writes ~/.config/o/o.env from the example (only if it doesn't
# exist), installs the systemd user unit and starts it. Safe to re-run: it
# rebuilds and restarts.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWARMRT="${SWARMRT:-$ROOT/../swarmrt}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "install: missing '$1' ($2)" >&2; exit 1; }; }
need git "git"
need make "build-essential"
need cc "build-essential"
need perl "perl"
need sqlite3 "sqlite3"
need gh "GitHub CLI, then: gh auth login"
need claude "Claude Code CLI, then log in once interactively"
command -v bwrap >/dev/null 2>&1 || echo "install: note: bubblewrap not found; agents will run unsandboxed unless you install it (O_SANDBOX=bwrap)"

if [ ! -d "$SWARMRT/.git" ]; then
  git clone https://github.com/skyblanket/swarmrt "$SWARMRT"
else
  git -C "$SWARMRT" pull --ff-only -q || true
fi
make -C "$SWARMRT" swc libswarmrt >/dev/null
make -C "$ROOT" SWARMRT="$SWARMRT" >/dev/null
mkdir -p "$HOME/.local/bin" "$HOME/.config/o" "$HOME/.config/systemd/user" "$HOME/.o"
install -m 755 "$ROOT/bin/swarmd" "$HOME/.local/bin/swarmd"

if [ ! -f "$HOME/.config/o/o.env" ]; then
  sed "s|%h|$HOME|g" "$ROOT/deploy/o.env.example" > "$HOME/.config/o/o.env"
  chmod 600 "$HOME/.config/o/o.env"
  echo "install: wrote ~/.config/o/o.env; set O_API_TOKEN and review it"
fi
install -m 644 "$ROOT/deploy/o.service" "$HOME/.config/systemd/user/o.service"
systemctl --user daemon-reload
systemctl --user enable o >/dev/null 2>&1
systemctl --user restart o
echo "install: O is running. systemctl --user status o  |  journalctl --user -u o -f"
echo "install: to survive logout: loginctl enable-linger \"$USER\""
