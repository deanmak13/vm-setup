#!/usr/bin/env bash
# ci-buildx-reaper.sh — Install the daily reaper for ORPHANED buildx cache
# volumes on the CI host (see bin/ci-buildx-reaper for the exact deletion rule).
#
# Installs:
#   /usr/local/bin/ci-buildx-reaper            (from bin/)
#   /etc/ci-buildx-reaper/active-builders.txt  (from buildx-reaper/; kept if it exists)
#   /etc/default/ci-buildx-reaper              (ALERT_REPO for runner-failure-alert)
#   ci-buildx-reaper.service + .timer          (daily; OnFailure= files the alert)
#   runner-failure-alert (shared meta-alert)   (from bin/ and systemd/)
#
# Usage: sudo bash ci-buildx-reaper.sh [--alert-repo vm-setup]
# Re-running is safe: units and the binary are overwritten, the registry is not.
set -euo pipefail
ALERT_REPO=vm-setup
[[ "${1:-}" == "--alert-repo" ]] && ALERT_REPO="$2"
[[ "$ALERT_REPO" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--alert-repo must be a bare repo name" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 755 "$REPO_DIR/bin/ci-buildx-reaper" /usr/local/bin/ci-buildx-reaper
install -d -m 755 /etc/ci-buildx-reaper
if [[ ! -e /etc/ci-buildx-reaper/active-builders.txt ]]; then
    install -m 644 "$REPO_DIR/buildx-reaper/active-builders.txt" /etc/ci-buildx-reaper/active-builders.txt
fi
printf 'ALERT_REPO=%s\n' "$ALERT_REPO" > /etc/default/ci-buildx-reaper
install -m 755 "$REPO_DIR/bin/runner-failure-alert" /usr/local/bin/runner-failure-alert
install -m 644 "$REPO_DIR/systemd/runner-failure-alert@.service" /etc/systemd/system/runner-failure-alert@.service

cat > /etc/systemd/system/ci-buildx-reaper.service <<'UNIT'
[Unit]
Description=Reap orphaned buildx cache volumes on the CI host
OnFailure=runner-failure-alert@ci-buildx-reaper.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ci-buildx-reaper
UNIT

cat > /etc/systemd/system/ci-buildx-reaper.timer <<'UNIT'
[Unit]
Description=Run ci-buildx-reaper daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
UNIT

touch /var/log/ci-buildx-reaper.log
systemctl daemon-reload
systemctl enable --now ci-buildx-reaper.timer
echo "[ci-buildx-reaper] installed; daily timer enabled (alerts to deanmak13/$ALERT_REPO)"
