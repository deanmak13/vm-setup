#!/usr/bin/env bash
# zombie-monitor.sh — Install a cron job that checks for zombie processes
# and logs an alert when they exceed a threshold.
#
# Usage:
#   sudo bash ~/vm-setup/zombie-monitor.sh              # Default threshold: 5
#   sudo bash ~/vm-setup/zombie-monitor.sh --threshold 3 # Custom threshold
#
# What it does:
#   1. Installs a check script to /usr/local/bin/check-zombies
#   2. Creates a cron job that runs every 5 minutes
#   3. Alerts via syslog (logger) and a dedicated log file at
#      /var/log/zombie-alerts.log
#   4. Sets up logrotate for the alert log

set -euo pipefail

THRESHOLD=5

log() { echo "[zombie-monitor] $*"; }
err() { echo "[zombie-monitor] ERROR: $*" >&2; exit 1; }

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

# --- Must run as root ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)"
fi

log "Setting up zombie process monitor (threshold: $THRESHOLD)..."

# --- Install the check script ---
cat > /usr/local/bin/check-zombies <<SCRIPT
#!/usr/bin/env bash
# check-zombies — Count zombie processes and alert if above threshold
THRESHOLD=$THRESHOLD
LOGFILE="/var/log/zombie-alerts.log"

ZOMBIE_COUNT=\$(ps aux | awk '\$8 ~ /^Z/ {count++} END {print count+0}')

if [[ \$ZOMBIE_COUNT -ge \$THRESHOLD ]]; then
    TIMESTAMP=\$(date '+%Y-%m-%d %H:%M:%S')
    MSG="ALERT: \$ZOMBIE_COUNT zombie processes detected (threshold: \$THRESHOLD)"

    # Log to syslog
    logger -t zombie-monitor -p daemon.warning "\$MSG"

    # Log to dedicated file with process details
    {
        echo "[\$TIMESTAMP] \$MSG"
        echo "  Zombie processes:"
        ps aux | awk '\$8 ~ /^Z/ {printf "    PID=%-8s PPID=%-8s CMD=%s\n", \$2, \$3, \$11}'
        echo ""
    } >> "\$LOGFILE"
fi
SCRIPT

chmod +x /usr/local/bin/check-zombies

# --- Install cron job (every 5 minutes) ---
CRON_LINE="*/5 * * * * /usr/local/bin/check-zombies"
CRON_FILE="/etc/cron.d/zombie-monitor"

echo "# Zombie process monitor — alerts when zombies exceed threshold" > "$CRON_FILE"
echo "$CRON_LINE" >> "$CRON_FILE"
chmod 644 "$CRON_FILE"

# --- Set up logrotate ---
cat > /etc/logrotate.d/zombie-alerts <<'ROTATE'
/var/log/zombie-alerts.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
ROTATE

log "Installed /usr/local/bin/check-zombies"
log "Cron job: every 5 minutes via /etc/cron.d/zombie-monitor"
log "Alerts go to: syslog (daemon.warning) + /var/log/zombie-alerts.log"
log "Test with: /usr/local/bin/check-zombies"
log "Done."
