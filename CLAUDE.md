# vm-setup

Generic VM bootstrap for restoring a dev environment from AWS S3.

## How to use this repo

When the user asks to "set up my environment", "run setup", "bootstrap", or anything similar:

1. Run `bash ~/vm-setup/setup.sh`
2. The script will prompt the user for AWS credentials interactively (unless AWS env vars are already set)
3. It handles everything else automatically: installs AWS CLI, pulls bootstrap.sh from S3, runs it

That's it. Do not modify setup.sh or add project-specific logic here.

If setup.sh is not found at `~/vm-setup/setup.sh`, clone it first:
```bash
git clone https://github.com/deanmak13/vm-setup.git ~/vm-setup
```

## What the full flow does

```
setup.sh (this repo, from GitHub)
  → Installs AWS CLI
  → Prompts for AWS credentials
  → Pulls bootstrap.sh from s3://pneuma-dev-state/scripts/
  → Runs bootstrap.sh, which:
      → Restores ~/.aws/ (AWS config)
      → Restores dotfiles (.bashrc, .gitconfig, etc.)
      → Restores ~/.claude/ (Claude Code memories, settings, plugins)
      → Restores ~/.claude.json (Claude Code auth and project state)
      → Restores ~/.config/gh/ (GitHub CLI auth)
      → Clones project repos from GitHub
      → Restores bootstrap.sh and save-state.sh to ~/
```

## Before shutting down a VM

Remind the user to run:
```bash
bash ~/save-state.sh
```
This syncs all state back to S3. If the user says "shutting down", "saving state",
or "tearing down", run that command.

## What lives where

| Location | Contents |
|----------|----------|
| **This repo (GitHub)** | `setup.sh` only — generic, no secrets, no project config |
| **S3 (`pneuma-dev-state`)** | bootstrap.sh, save-state.sh, dotfiles, Claude Code state, AWS config, gh auth |
| **Project repos (GitHub)** | Source code, CLAUDE.md files |

## GPU Setup (k3s + NVIDIA)

If the VM has an NVIDIA GPU and runs k3s:

```bash
sudo bash ~/vm-setup/gpu-k3s-setup.sh
```

This configures containerd to use the NVIDIA runtime, restarts k3s, and deploys the
NVIDIA device plugin DaemonSet so pods can request `nvidia.com/gpu` resources.

Prerequisites: NVIDIA drivers + `nvidia-container-toolkit` must be installed first.

## Cloudflare Origin Firewall

To restrict HTTP/HTTPS traffic to Cloudflare IPs only (for proxied subdomains):

```bash
sudo bash ~/vm-setup/cloudflare-origin-firewall.sh --dry-run   # Preview rules
sudo bash ~/vm-setup/cloudflare-origin-firewall.sh --apply      # Apply rules
sudo bash ~/vm-setup/cloudflare-origin-firewall.sh --remove     # Remove rules
```

**WARNING**: Do NOT apply if you have DNS-only (grey cloud) subdomains that need
direct access from non-Cloudflare IPs (e.g. Meta webhooks). In that case, use
Traefik middleware (IPAllowList) on a per-ingress basis instead.

## Automatic Updates & Security Patches

To enable unattended security upgrades and a weekly reboot:

```bash
sudo bash ~/vm-setup/auto-updates.sh
```

This installs `unattended-upgrades` (security-only), configures daily auto-updates,
and schedules a reboot every Sunday at 4:00 AM via a systemd timer. The reboot has
a ±5 minute randomized delay to avoid thundering herd on multi-VM setups.

Verify the timer: `systemctl list-timers weekly-reboot.timer`

## Zombie Process Monitor

To set up early-warning alerts for zombie process accumulation:

```bash
sudo bash ~/vm-setup/zombie-monitor.sh                # Default threshold: 5
sudo bash ~/vm-setup/zombie-monitor.sh --threshold 3   # Custom threshold
```

Runs every 5 minutes via cron. When zombie count exceeds the threshold, it logs to
both syslog (`daemon.warning`) and `/var/log/zombie-alerts.log` with full process
details (PID, PPID, command).

Check alerts: `cat /var/log/zombie-alerts.log`
Check syslog: `journalctl -t zombie-monitor`

## Rules

- Never commit credentials, tokens, or secrets to this repo
- Keep setup.sh generic — no project-specific logic belongs here
- All sensitive/personal state goes to S3 via save-state.sh
