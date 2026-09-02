#!/usr/bin/env bash
# runner-refresh.sh — install the idle-gated runner refresh on the CI host.
#
# Companion to the needrestart override (needrestart-actions-runner.conf,
# bootstrap §4b): needrestart no longer restarts the actions.runner.* units
# after a library patch, so bin/runner-refresh does it instead — per unit,
# only once that unit holds a replaced shared object AND has no job running.
# Every 5 minutes via runner-refresh.timer; decisions land in
# /var/log/runner-refresh.log and the journal (tag runner-refresh).
#
# The program is a real file (bin/runner-refresh) rather than a heredoc in this
# installer so tests/runner-refresh.test.sh can source it and kcov can measure
# it; the reaper and janitor predate that and still embed theirs.
#
# Usage: sudo bash runner-refresh.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo "[runner-refresh] $*"; }
err() { echo "[runner-refresh] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "This script must be run as root (use sudo)"

install -m 755 "$REPO_DIR/bin/runner-refresh" /usr/local/bin/runner-refresh

cat > /etc/systemd/system/runner-refresh.service <<'UNIT'
[Unit]
Description=Restart idle GitHub Actions runners that hold replaced libraries

[Service]
Type=oneshot
ExecStart=/usr/local/bin/runner-refresh
UNIT

cat > /etc/systemd/system/runner-refresh.timer <<'UNIT'
[Unit]
Description=Run runner-refresh every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

touch /var/log/runner-refresh.log
cat > /etc/logrotate.d/runner-refresh <<'ROT'
/var/log/runner-refresh.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
ROT

systemctl daemon-reload
systemctl enable --now runner-refresh.timer
log "installed and started runner-refresh.timer"
