#!/usr/bin/env bash
# ci-disk-janitor.sh — Install an hourly disk janitor on the CI host.
#
# 2026-08-15: the 72GB root filled to 100% (ENOSPC failed engine CI and
# IO-crushed every runner). The hogs were runner `_work` trees (~19GB across
# 13 runners), /tmp build junk, docker layer/builder cache, and journal
# logs. Nothing on the host reclaimed any of it automatically.
#
# Policy: hourly check; below THRESHOLD% usage do nothing. Above it, clean
# in escalating stages, cheapest-to-rebuild first, re-checking after each:
#   1. /tmp entries older than 1 day (never the shared pip cache)
#   2. docker builder cache beyond 10GB + images unused for 72h
#   3. journal logs beyond 200MB
#   4. `_work` trees of runners with NO active Worker process (they
#      re-clone on next job; costs ~1min of npm/pip restore)
# Never touches: active runners' _work, /home/ubuntu/.cache/pip-shared,
# k3s state, docker volumes.
#
# Usage: sudo bash ci-disk-janitor.sh [--threshold 80]

set -euo pipefail
THRESHOLD=80
[[ "${1:-}" == "--threshold" ]] && THRESHOLD="$2"
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

cat > /usr/local/bin/ci-disk-janitor <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
THRESHOLD=__THRESHOLD__
LOG=/var/log/ci-disk-janitor.log
note() { echo "$(date -Is) $*" >> "$LOG"; logger -t ci-disk-janitor "$*"; }
usage() { df --output=pcent / | tail -1 | tr -dc '0-9'; }

(( $(usage) < THRESHOLD )) && exit 0
note "usage $(usage)% >= ${THRESHOLD}% — cleaning"

find /tmp -maxdepth 1 -mtime +1 -not -name 'pip-shared' -exec rm -rf {} + 2>/dev/null
(( $(usage) < THRESHOLD )) && { note "done after /tmp — $(usage)%"; exit 0; }

docker builder prune -af --keep-storage 10GB >/dev/null 2>&1
docker image prune -af --filter 'until=72h' >/dev/null 2>&1
(( $(usage) < THRESHOLD )) && { note "done after docker — $(usage)%"; exit 0; }

journalctl --vacuum-size=200M >/dev/null 2>&1
(( $(usage) < THRESHOLD )) && { note "done after journal — $(usage)%"; exit 0; }

ACTIVE=$(ps -eo args | grep '[R]unner.Worker' | grep -o 'actions-runner-[a-z0-9-]*' | sort -u)
for d in /home/ubuntu/actions-runner-*/; do
    name=$(basename "$d")
    echo "$ACTIVE" | grep -qx "$name" && continue
    [ -d "$d/_work" ] && { rm -rf "$d/_work"; note "pruned $name/_work"; }
done
note "finished — $(usage)%"
SCRIPT
sed -i "s/__THRESHOLD__/$THRESHOLD/" /usr/local/bin/ci-disk-janitor
chmod 755 /usr/local/bin/ci-disk-janitor

cat > /etc/systemd/system/ci-disk-janitor.service <<'UNIT'
[Unit]
Description=CI host disk janitor

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ci-disk-janitor
UNIT

cat > /etc/systemd/system/ci-disk-janitor.timer <<'UNIT'
[Unit]
Description=Run ci-disk-janitor hourly

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
UNIT

touch /var/log/ci-disk-janitor.log
systemctl daemon-reload
systemctl enable --now ci-disk-janitor.timer
echo "[ci-disk-janitor] installed (threshold ${THRESHOLD}%)"
