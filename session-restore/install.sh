#!/usr/bin/env bash
# session-restore/install.sh — install tmux/agent-session snapshot + restore as systemd USER units.
# No sudo. Idempotent. Usage: bash session-restore/install.sh [--dry-run]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"; UNITS="$HOME/.config/systemd/user"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
run() { if [[ $DRY == 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }
run mkdir -p "$BIN" "$UNITS" "$HOME/.cache/pneuma-session-restore"
run install -m 755 "$HERE/snapshot.sh" "$BIN/pneuma-session-snapshot"
run install -m 755 "$HERE/restore.sh" "$BIN/pneuma-session-restore"
for u in pneuma-session-snapshot.service pneuma-session-snapshot.timer pneuma-session-restore.service; do
  run install -m 644 "$HERE/systemd/$u" "$UNITS/$u"
done
run systemctl --user daemon-reload
run systemctl --user enable --now pneuma-session-snapshot.timer
run systemctl --user enable pneuma-session-restore.service   # runs at next boot; never started now (restore is idempotent anyway)
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]]; then
  echo "WARNING: linger is off; the user manager will not start at boot. Run (needs sudo): sudo loginctl enable-linger $USER" >&2
fi
echo "installed. First snapshot: $(date -u +%H:%M)Z + 5 min timer; restore on next boot."
