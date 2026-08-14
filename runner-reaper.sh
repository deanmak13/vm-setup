#!/usr/bin/env bash
# runner-reaper.sh — Install a watchdog that reaps wedged GitHub Actions
# runner workers on the CI host.
#
# THE DISEASE (observed 2026-08-14, three separate times in one day):
# a Runner.Worker process survives its job — after a cancellation, an
# OOM kill of its child, or a lost connection — and keeps burning a full
# core while GitHub shows the runner "busy". Queued jobs then wait behind
# a phantom, and every OTHER repo's jobs on this 4-core host crawl. The
# portal admin gate was measured at 2-5h under this contention vs ~15min
# clean. Nothing reaps these workers; a human had to notice and restart
# runner services by hand.
#
# THE CURE: every 5 minutes, for each repo runner whose Runner.Worker
# process has existed longer than a grace period, ask GitHub whether that
# repo has ANY in-progress workflow run. No in-progress run + old Worker
# = zombie → restart that repo's runner services (restart is safe: the
# listener re-registers and picks queued work up immediately).
#
# A repo with at least one in-progress run is always left alone — we
# cannot attribute runs to a specific runner cheaply, so a zombie can
# only survive while a sibling run of the SAME repo is genuinely live,
# and it is reaped on the first quiet cycle after.
#
# Requires: a GitHub token with repo read scope at /root/.runner-reaper-token
# (mode 600). The installer copies it from --token-file.
#
# Usage:
#   sudo bash runner-reaper.sh --token-file /path/to/token [--grace-seconds 600]

set -euo pipefail

GRACE=600
TOKEN_FILE=""

log() { echo "[runner-reaper] $*"; }
err() { echo "[runner-reaper] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token-file) TOKEN_FILE="$2"; shift 2 ;;
        --grace-seconds) GRACE="$2"; shift 2 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || err "This script must be run as root (use sudo)"
[[ -n "$TOKEN_FILE" && -f "$TOKEN_FILE" ]] || err "--token-file is required and must exist"

install -m 600 "$TOKEN_FILE" /root/.runner-reaper-token
log "token installed at /root/.runner-reaper-token"

cat > /usr/local/bin/runner-reaper <<'SCRIPT'
#!/usr/bin/env bash
# Reap GitHub Actions Runner.Worker zombies. Installed by vm-setup/runner-reaper.sh.
set -uo pipefail

GRACE=__GRACE__
TOKEN=$(cat /root/.runner-reaper-token)
OWNER=deanmak13
LOG=/var/log/runner-reaper.log

note() { echo "$(date -Is) $*" >> "$LOG"; logger -t runner-reaper "$*"; }

# repo → oldest Worker age (seconds), from the worker's runner directory path.
declare -A OLDEST
while read -r pid etimes args; do
    # /home/ubuntu/actions-runner-<repo>[-N]/bin.../Runner.Worker
    dir=${args#*actions-runner-}
    repo=${dir%%/*}
    repo=${repo%-2}; repo=${repo%-3}
    [[ -n "$repo" ]] || continue
    cur=${OLDEST[$repo]:-0}
    (( etimes > cur )) && OLDEST[$repo]=$etimes
done < <(ps -eo pid,etimes,args | grep '[R]unner.Worker' || true)

for repo in "${!OLDEST[@]}"; do
    age=${OLDEST[$repo]}
    (( age < GRACE )) && continue
    # Two observed failure shapes pull in opposite directions:
    #  - a run can report "queued" while its job is already executing
    #    (2026-08-14 AM: reaper killed a live 25-min gate), so queued
    #    cannot simply mean dead;
    #  - a wedged runner holds workers busy while runs sit queued for
    #    HOURS (2026-08-14 PM: 13h-old queue, zero in_progress), so
    #    queued cannot simply mean alive either.
    # Resolution: in_progress always blocks reaping; queued blocks only
    # while the newest queued run is younger than QUEUED_GRACE — the
    # status-lag window is minutes, a wedge is hours.
    QUEUED_GRACE=1200
    api() { curl -sf -m 20 -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$repo/actions/runs?status=$1&per_page=1"; }
    inprog=$(api in_progress | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_count"])' 2>/dev/null)
    [[ "$inprog" =~ ^[0-9]+$ ]] || { note "skip $repo: API check failed"; continue; }
    (( inprog > 0 )) && continue
    queued_age=$(api queued | python3 -c '
import json,sys,datetime
d=json.load(sys.stdin)
runs=d.get("workflow_runs") or []
if not runs: print(-1)
else:
    t=datetime.datetime.fromisoformat(runs[0]["created_at"].replace("Z","+00:00"))
    print(int((datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()))' 2>/dev/null)
    [[ "$queued_age" =~ ^-?[0-9]+$ ]] || { note "skip $repo: API check failed"; continue; }
    if (( queued_age >= 0 && queued_age < QUEUED_GRACE )); then continue; fi
    units=$(systemctl list-units "actions.runner.$OWNER-$repo.*" --no-legend --plain | awk '{print $1}')
    [[ -n "$units" ]] || continue
    note "REAP $repo: Worker age ${age}s, in_progress=0 — restarting: $units"
    # shellcheck disable=SC2086
    systemctl restart $units
done
SCRIPT
sed -i "s/__GRACE__/$GRACE/" /usr/local/bin/runner-reaper
chmod 755 /usr/local/bin/runner-reaper

cat > /etc/systemd/system/runner-reaper.service <<'UNIT'
[Unit]
Description=Reap wedged GitHub Actions runner workers

[Service]
Type=oneshot
ExecStart=/usr/local/bin/runner-reaper
UNIT

cat > /etc/systemd/system/runner-reaper.timer <<'UNIT'
[Unit]
Description=Run runner-reaper every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

touch /var/log/runner-reaper.log
cat > /etc/logrotate.d/runner-reaper <<'ROT'
/var/log/runner-reaper.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
ROT

systemctl daemon-reload
systemctl enable --now runner-reaper.timer
log "installed and started runner-reaper.timer (grace ${GRACE}s)"
