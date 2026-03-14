#!/usr/bin/env bash
# auto-updates.sh — Configure unattended-upgrades for automatic security patches
# and schedule a weekly reboot at 4am Sunday.
#
# Usage:
#   sudo bash ~/vm-setup/auto-updates.sh
#
# What it does:
#   1. Installs and configures unattended-upgrades (security patches only)
#   2. Schedules a weekly reboot via systemd timer (Sunday 4:00 AM)
#   3. Enables automatic removal of unused kernel/dependency packages

set -euo pipefail

log() { echo "[auto-updates] $*"; }
err() { echo "[auto-updates] ERROR: $*" >&2; exit 1; }

# --- Must run as root ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)"
fi

# --- Install unattended-upgrades ---
log "Installing unattended-upgrades..."
apt-get update -qq
apt-get install -y -qq unattended-upgrades apt-listchanges > /dev/null 2>&1

# --- Configure unattended-upgrades ---
log "Configuring unattended-upgrades..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'UUCFG'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Remove unused automatically installed kernel-related packages
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Remove unused dependencies after upgrade
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Remove new unused dependencies after upgrade
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Log to syslog
Unattended-Upgrade::SyslogEnable "true";

// Don't auto-reboot here — we handle reboots via systemd timer
Unattended-Upgrade::Automatic-Reboot "false";
UUCFG

# --- Enable automatic updates ---
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTOCFG'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
AUTOCFG

log "Unattended-upgrades configured (security patches only)."

# --- Schedule weekly reboot at 4am Sunday via systemd ---
log "Setting up weekly reboot timer (Sunday 4:00 AM)..."

cat > /etc/systemd/system/weekly-reboot.service <<'SVC'
[Unit]
Description=Weekly scheduled reboot for pending updates
Documentation=man:systemctl(1)

[Service]
Type=oneshot
ExecStart=/usr/sbin/shutdown -r +1 "Scheduled weekly reboot for updates"
SVC

cat > /etc/systemd/system/weekly-reboot.timer <<'TMR'
[Unit]
Description=Weekly reboot timer (Sunday 4am)

[Timer]
OnCalendar=Sun *-*-* 04:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now weekly-reboot.timer

log "Weekly reboot scheduled: Sunday 4:00 AM (±5min jitter)."
log "Verify with: systemctl list-timers weekly-reboot.timer"
log "Done."
