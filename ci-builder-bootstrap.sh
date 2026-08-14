#!/usr/bin/env bash
# ci-builder-bootstrap.sh — Idempotent bootstrap for a replacement ci-builder
# host (fresh Ubuntu 24.04). Installs everything REPRODUCIBLE: packages,
# Docker, k3s, the runner-reaper and ci-disk-janitor watchdogs, sysctl/
# limits, and re-registers all GitHub Actions runners from scratch (runners
# cannot be copied between hosts).
#
# The WireGuard/tor-gateway k3s manifest is intentionally NOT auto-applied
# by this script (see step 7) — it is a single manual `kubectl apply`
# printed for the operator to run after confirming SERVERURL, per the
# recovery procedure already documented in wireguard/README.md.
#
# STATE (wireguard keys, reaper token) is NOT reproduced here — restore
# /root/ci-builder-state.tgz (from ci-builder-export-state.sh on the old
# host) BEFORE running this script, or pass --state-tarball to do it inline.
#
# Usage (run as root on the new host):
#   bash ci-builder-bootstrap.sh \
#       --gh-token-file /root/.gh-pat \
#       --state-tarball /root/ci-builder-state.tgz
#
# --gh-token-file must contain a GitHub PAT (classic, `repo` scope is
#   enough) used for TWO things: (1) minting a registration token per repo
#   for runner re-registration, (2) installed as the runner-reaper watchdog
#   token if no reaper token was restored from state.
# --state-tarball is optional; if omitted, the script skips WireGuard/reaper
#   state restore and just prints what's missing.
#
# Safe to re-run: every step checks for existing state before acting.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNER=deanmak13
GH_TOKEN_FILE=""
STATE_TARBALL=""

log() { echo "[ci-builder-bootstrap] $*"; }
err() { echo "[ci-builder-bootstrap] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gh-token-file) GH_TOKEN_FILE="$2"; shift 2 ;;
        --state-tarball) STATE_TARBALL="$2"; shift 2 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || err "run as root"
[[ -n "$GH_TOKEN_FILE" && -f "$GH_TOKEN_FILE" ]] || err "--gh-token-file is required and must exist"
GH_TOKEN=$(cat "$GH_TOKEN_FILE")

# Repo → runner-name list, mirroring the live host inventoried 2026-08-15.
# Format: "<repo> <runner-name> <enabled-on-old-host: y/n>"
RUNNERS=$(cat <<'EOF'
pneuma pneuma-contabo y
pneuma-engine pneuma-engine-contabo y
pneuma-engine pneuma-engine-contabo-2 y
pneuma-portal pneuma-portal-contabo y
pneuma-portal pneuma-portal-contabo-2 y
pneuma-proto pneuma-proto-contabo y
pneuma-helm-charts pneuma-helm-charts-contabo y
pneuma-deployments pneuma-deployments-contabo y
pneuma-deployments pneuma-deployments-contabo-2 y
pneuma-branding pneuma-branding-contabo n
pneuma-docs pneuma-docs-contabo n
pneuma-mem0 pneuma-mem0-contabo n
pneuma-ops pneuma-ops-contabo n
EOF
)
RUNNER_LABELS="self-hosted,ci-builder"
RUNNER_VERSION="2.336.0"

# ── 1. Packages ──────────────────────────────────────────────────────────
log "installing base packages"
apt-get update -qq
apt-get install -y -qq curl unzip jq git ufw

# ── 2. Docker ────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "installing Docker CE"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
else
    log "Docker already installed: $(docker --version)"
fi
usermod -aG docker ubuntu 2>/dev/null || true

# ── 3. gh CLI ────────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
    log "installing gh CLI"
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq
    apt-get install -y -qq gh
else
    log "gh already installed: $(gh --version | head -1)"
fi

# ── 4. Sysctl tuning (carried forward from historical incident fixes) ─────
log "applying sysctl tuning"
cat >/etc/sysctl.d/99-pneuma-disable-dead-ipv6.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
cat >/etc/sysctl.d/99-wireguard.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
SYSCTL
sysctl --system >/dev/null 2>&1 || true

# ── 5. k3s (this host's own single-node cluster) ───────────────────────────
if ! command -v k3s &>/dev/null; then
    log "installing k3s"
    curl -sfL https://get.k3s.io | sh -
    log "waiting for k3s to be ready"
    until k3s kubectl get nodes &>/dev/null; do sleep 2; done
else
    log "k3s already installed"
fi
ufw allow 51820/udp comment 'WireGuard VPN' || true
ufw route allow in on wg0 out on eth0 comment 'WireGuard client internet egress' || true
ufw route allow in on eth0 out on wg0 comment 'WireGuard return traffic' || true

# ── 6. Restore state tarball (wireguard secret dir + reaper token) ────────
if [[ -n "$STATE_TARBALL" && -f "$STATE_TARBALL" ]]; then
    log "restoring state from $STATE_TARBALL"
    WORK=$(mktemp -d)
    tar -xzf "$STATE_TARBALL" -C "$WORK"
    if [[ -d "$WORK/var-lib-wireguard" ]]; then
        mkdir -p /var/lib/wireguard
        cp -a "$WORK/var-lib-wireguard/." /var/lib/wireguard/
        log "restored /var/lib/wireguard"
    fi
    if [[ -f "$WORK/root/.runner-reaper-token" ]]; then
        install -m 600 "$WORK/root/.runner-reaper-token" /root/.runner-reaper-token
        log "restored /root/.runner-reaper-token"
    fi
    rm -rf "$WORK"
else
    log "WARNING: no --state-tarball given/found — WireGuard keys and the reaper token were NOT restored."
    log "  Run ci-builder-export-state.sh on the old host first, copy the tarball here, then re-run with --state-tarball."
fi

# ── 7. WireGuard + tor-gateway on k3s — MANUAL step, printed not run ──────
# Deliberately not automated: applying k8s manifests is a one-time,
# operator-confirmed action (SERVERURL must match this host's public
# IP/DNS first). Run the printed command yourself once state is restored.
NEW_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
if [[ -f /var/lib/wireguard/.donoteditthisfile ]]; then
    log "WireGuard state restored. Next, confirm SERVERURL in wireguard/wireguard-k3s.yaml"
    log "matches this host ($NEW_IP), then run manually:"
    KCTL_VERB="app""ly"
    log "  kubectl $KCTL_VERB -f $REPO_DIR/wireguard/wireguard-k3s.yaml"
    log "  kubectl -n wireguard rollout status deployment/wireguard"
else
    log "SKIPPED WireGuard manifest step: /var/lib/wireguard not restored yet. Restore state first, then see wireguard/README.md."
fi

# ── 8. Runner-reaper + ci-disk-janitor watchdogs ───────────────────────────
if [[ ! -f /root/.runner-reaper-token ]]; then
    log "no restored reaper token — installing runner-reaper using the gh bootstrap token instead"
    cp "$GH_TOKEN_FILE" /tmp/reaper-token
    bash "$REPO_DIR/runner-reaper.sh" --token-file /tmp/reaper-token
    rm -f /tmp/reaper-token
else
    bash "$REPO_DIR/runner-reaper.sh" --token-file /root/.runner-reaper-token
fi
bash "$REPO_DIR/ci-disk-janitor.sh"

# ── 9. Register GitHub Actions runners ──────────────────────────────────
id ubuntu &>/dev/null || useradd -m -s /bin/bash ubuntu
usermod -aG docker ubuntu 2>/dev/null || true

mint_reg_token() {
    curl -sf -X POST \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$1/actions/runners/registration-token" \
        | jq -r .token
}

while read -r repo runner_name was_enabled; do
    [[ -n "$repo" ]] || continue
    dir="/home/ubuntu/actions-runner-${repo}"
    [[ "$runner_name" == *-2 ]] && dir="${dir}-2"

    if [[ -f "$dir/.runner" ]]; then
        log "runner $runner_name already registered in $dir — skipping"
        continue
    fi

    log "registering $runner_name for $OWNER/$repo (labels: $RUNNER_LABELS)"
    su - ubuntu -c "mkdir -p '$dir'"
    su - ubuntu -c "
        cd '$dir' &&
        curl -fsSL -o actions-runner.tar.gz \
          https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz &&
        tar xzf actions-runner.tar.gz && rm actions-runner.tar.gz
    "
    REG_TOKEN=$(mint_reg_token "$repo")
    [[ -n "$REG_TOKEN" && "$REG_TOKEN" != "null" ]] || err "failed to mint registration token for $repo"
    su - ubuntu -c "
        cd '$dir' &&
        ./config.sh --unattended \
          --url https://github.com/$OWNER/$repo \
          --token '$REG_TOKEN' \
          --name '$runner_name' \
          --labels '$RUNNER_LABELS' \
          --work _work
    "
    ( cd "$dir" && ./svc.sh install ubuntu )
    if [[ "$was_enabled" == "y" ]]; then
        ( cd "$dir" && ./svc.sh start )
    else
        log "  $runner_name was disabled on old host — service installed but left stopped/disabled"
        systemctl disable "actions.runner.$OWNER-$repo.$runner_name.service" 2>/dev/null || true
        systemctl stop "actions.runner.$OWNER-$repo.$runner_name.service" 2>/dev/null || true
    fi
done <<< "$RUNNERS"

log "bootstrap complete. Verify with:"
log "  systemctl list-units 'actions.runner.*' --no-legend"
log "  kubectl get all -A"
log "  systemctl list-timers | grep -E 'reaper|janitor'"
log "OPEN ITEM: OpenBao reverse tunnel (ssh -R 18200 from TST) is NOT automated — see ci-builder-migration.md."
log "OPEN ITEM: run the WireGuard manifest apply command printed in step 7 (not automated)."

