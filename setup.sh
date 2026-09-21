#!/usr/bin/env bash
# setup.sh — First-run bootstrap for a fresh VM instance.
# Installs AWS CLI, configures credentials, then pulls the real
# bootstrap script from S3 and runs it.
#
# Usage:
#   bash setup.sh                          # Interactive (prompts for credentials)
#   bash setup.sh --env                    # Use existing AWS_* env vars
#
# What this does NOT contain: credentials, dotfiles, project configs.
# All of that lives in S3 and gets pulled by bootstrap.sh.

set -euo pipefail

S3_BUCKET="s3://pneuma-dev-state"
BOOTSTRAP_PATH="scripts/bootstrap.sh"

# Resolve target user — if run as root, install for the non-root user
if [ "$(id -u)" -eq 0 ]; then
    TARGET_USER="${SUDO_USER:-$(ls /home/ | head -1)}"
    TARGET_HOME="/home/$TARGET_USER"
    log_prefix="[vm-setup] (as root, target: $TARGET_USER)"
else
    TARGET_USER="$(whoami)"
    TARGET_HOME="$HOME"
    log_prefix="[vm-setup]"
fi

LOCAL_BIN="$TARGET_HOME/.local/bin"
export PATH="$LOCAL_BIN:$PATH"

log() { echo "$log_prefix $*"; }
err() { echo "$log_prefix ERROR: $*" >&2; exit 1; }

# --- Install prerequisites ---
log "Installing prerequisites (unzip, curl, Playwright system deps)..."
apt-get update -qq
apt-get install -y -qq unzip curl \
    libatk1.0-0 libatk-bridge2.0-0 libcups2 libxdamage1 libxrandr2 \
    libgbm1 libpango-1.0-0 libcairo2 libasound2t64 libnspr4 libnss3 \
    libxcomposite1 libxfixes3 libdrm2 libxkbcommon0 \
    libxcursor1 libxi6 libxtst6 libxss1 libx11-xcb1 \
    libpangocairo-1.0-0 libgdk-pixbuf2.0-0 \
    || err "Failed to install prerequisites. Check apt."

# --- Install AWS CLI if missing ---
if ! command -v aws &>/dev/null; then
    log "Installing AWS CLI..."
    mkdir -p "$LOCAL_BIN"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -qo /tmp/awscliv2.zip -d /tmp/aws-cli-install
    /tmp/aws-cli-install/aws/install --install-dir "$TARGET_HOME/.local/aws-cli" --bin-dir "$LOCAL_BIN" --update
    rm -rf /tmp/awscliv2.zip /tmp/aws-cli-install
    # Fix ownership if running as root
    [ "$(id -u)" -eq 0 ] && chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.local"
    log "AWS CLI installed: $(aws --version)"
else
    log "AWS CLI already installed: $(aws --version)"
fi

# --- Configure AWS credentials ---
if [[ "${1:-}" == "--env" ]]; then
    log "Using AWS credentials from environment variables..."
    : "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID env var}"
    : "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY env var}"
    : "${AWS_DEFAULT_REGION:?Set AWS_DEFAULT_REGION env var}"
else
    if ! aws sts get-caller-identity &>/dev/null; then
        log "AWS credentials needed. Running 'aws configure'..."
        aws configure
    else
        log "AWS credentials already configured."
    fi
fi

# --- Verify credentials work ---
if ! aws sts get-caller-identity &>/dev/null; then
    err "AWS credentials invalid. Check your access key and secret."
fi
log "Authenticated as: $(aws sts get-caller-identity --query Arn --output text)"

# --- Test bucket access ---
if ! aws s3 ls "$S3_BUCKET/" &>/dev/null; then
    err "Cannot access $S3_BUCKET. Check that the bucket exists and your IAM policy allows access."
fi

# --- Pull bootstrap.sh from S3 and run it ---
log "Pulling bootstrap.sh from S3..."
if aws s3 cp "$S3_BUCKET/$BOOTSTRAP_PATH" "$TARGET_HOME/bootstrap.sh"; then
    chmod +x "$TARGET_HOME/bootstrap.sh"
    [ "$(id -u)" -eq 0 ] && chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/bootstrap.sh"
    log "Running bootstrap.sh..."
    if [ "$(id -u)" -eq 0 ]; then
        su - "$TARGET_USER" -c "bash $TARGET_HOME/bootstrap.sh"
    else
        bash "$TARGET_HOME/bootstrap.sh"
    fi
else
    err "bootstrap.sh not found in S3 at $S3_BUCKET/$BOOTSTRAP_PATH. Run save-state.sh on an existing instance first."
fi

# ── Playwright: disable AppArmor sandbox restriction ──
# Required for Chromium to run without --no-sandbox on Ubuntu 23.10+
echo "kernel.apparmor_restrict_unprivileged_userns=0" | sudo tee /etc/sysctl.d/99-playwright.conf
sudo sysctl -p /etc/sysctl.d/99-playwright.conf

# --- Pneuma: disable dead IPv6 egress (2026-06-11; made durable 2026-09-21) ---
# The Contabo node's IPv6 path to ghcr.io is broken (connection reset), but
# containerd resolves AAAA and tries IPv6 FIRST -> ImagePullBackOff that never
# self-heals, because every backoff retry re-tries the same dead path.
#
# WHY SYSCTL ALONE WAS NOT ENOUGH (three recurrences: 2026-06-11, 09-07, 09-21).
# sysctl.d sets `all` and `default`, which apply to interfaces that appear
# AFTER systemd-sysctl runs. eth0 is brought up by systemd-networkd LATER and
# comes back with disable_ipv6=0 plus the static IPv6 address cloud-init wrote
# for it. The kernel then prefers IPv6, and pulls break again. Per-interface
# sysctl is a race we lose on every boot, so this is now fixed at the source:
# eth0 is declared IPv4-only in netplan, and cloud-init is stopped from
# regenerating an IPv6 address for it.
#
# The netplan file is DERIVED from the live interface, never hardcoded, so this
# stays correct on a rebuilt or re-addressed instance.

# 1. Stop cloud-init regenerating eth0 with an IPv6 address on every boot.
sudo tee /etc/cloud/cloud.cfg.d/99-pneuma-disable-network-config.cfg >/dev/null <<'CLOUDINIT'
# Pneuma: netplan below is the source of truth for eth0. cloud-init must not
# re-add the IPv6 address/route whose egress is dead. See setup.sh.
network: {config: disabled}
CLOUDINIT

# 2. Declare the primary interface IPv4-only. The netplan body is DERIVED from
#    the live system by derive-ipv4-netplan.sh (tested in tests/), never
#    hardcoded, so it stays correct on a rebuilt or re-addressed instance.
PNEUMA_IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
if PNEUMA_NETPLAN="$(./derive-ipv4-netplan.sh 2>/dev/null)"; then
  printf '%s\n' "$PNEUMA_NETPLAN" | sudo tee /etc/netplan/99-pneuma-ipv4-only.yaml >/dev/null
  sudo chmod 600 /etc/netplan/99-pneuma-ipv4-only.yaml
  # generate, NOT apply: generate validates and fails at the safe moment.
  # Applying a network change to a live remote host is an operator action with
  # a console fallback, not something a setup script does unattended.
  sudo netplan generate
else
  echo "WARN: could not derive IPv4 netplan; leaving existing netplan in place" >&2
fi

# 3. Belt and braces: sysctl still covers the window before netplan applies,
#    and any interface that is not eth0. `all`/`default` alone do NOT cover an
#    already-created interface, so the live interface is named explicitly.
sudo tee /etc/sysctl.d/99-pneuma-disable-dead-ipv6.conf >/dev/null <<SYSCTL
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.${PNEUMA_IFACE:-eth0}.disable_ipv6 = 1
SYSCTL
sudo sysctl --system >/dev/null 2>&1 || true

# 4. Verify, and say so loudly if it did not take -- a silent failure here
#    resurfaces days later as an unexplained ImagePullBackOff.
if [ "$(cat /proc/sys/net/ipv6/conf/${PNEUMA_IFACE:-eth0}/disable_ipv6 2>/dev/null)" != "1" ]; then
  echo "WARN: IPv6 still enabled on ${PNEUMA_IFACE:-eth0} -- registry pulls may fail" >&2
fi
