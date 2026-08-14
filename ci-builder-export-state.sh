#!/usr/bin/env bash
# ci-builder-export-state.sh — Run as root on the OLD ci-builder host BEFORE
# decommissioning it. Produces /root/ci-builder-state.tgz containing every
# piece of STATE that cannot be reproduced on a fresh host: the WireGuard
# secret directory (keys + peer configs, k3s-mounted at /var/lib/wireguard),
# the runner-reaper GitHub token, and a manifest of what was found so the
# new host's operator can sanity-check nothing was missed.
#
# Explicitly NOT exported (reproducible, not state):
#   - GitHub Actions runner .credentials / .runner files — runners cannot be
#     copied between hosts; every runner must re-register fresh on the new
#     host (see ci-builder-migration.md).
#   - k3s cluster objects (coredns/traefik/metrics-server/wireguard/tor-gateway)
#     — no PVCs exist on this host (confirmed via `kubectl get pvc -A` →
#     "No resources found"), so the whole cluster is reproducible from the
#     manifests already in this repo (wireguard/wireguard-k3s.yaml).
#   - docker images/buildx state — repulled/rebuilt on demand.
#
# Usage: sudo bash ci-builder-export-state.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

OUT=/root/ci-builder-state.tgz
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { echo "[export-state] $*"; }

mkdir -p "$WORK/var-lib-wireguard" "$WORK/root"

# --- WireGuard secret state (k3s hostPath-mounted, keys + peer configs) ---
if [[ -d /var/lib/wireguard ]]; then
    cp -a /var/lib/wireguard/. "$WORK/var-lib-wireguard/"
    log "captured /var/lib/wireguard ($(du -sh /var/lib/wireguard | cut -f1))"
else
    log "WARNING: /var/lib/wireguard not found — nothing to export for WireGuard"
fi

# --- runner-reaper GitHub token ---
if [[ -f /root/.runner-reaper-token ]]; then
    cp -a /root/.runner-reaper-token "$WORK/root/.runner-reaper-token"
    log "captured /root/.runner-reaper-token"
else
    log "WARNING: /root/.runner-reaper-token not found"
fi

# --- manifest: what runners/repos existed, for a diff against re-registration ---
{
    echo "# ci-builder-state manifest — generated $(date -Is) on $(hostname)"
    echo
    echo "## enabled actions.runner services (repo → runner name → labels)"
    for svc in /etc/systemd/system/actions.runner.*.service; do
        [[ -e "$svc" ]] || continue
        name=$(basename "$svc" .service)
        enabled=$(systemctl is-enabled "$name" 2>/dev/null || echo unknown)
        active=$(systemctl is-active "$name" 2>/dev/null || echo unknown)
        workdir=$(grep -oP '^WorkingDirectory=\K.*' "$svc" || true)
        echo "- $name  enabled=$enabled active=$active workdir=$workdir"
    done
    echo
    echo "## k3s: kubectl get all -A (informational only — cluster is reproducible, not state)"
    kubectl get all -A 2>&1 || echo "(kubectl unavailable)"
    echo
    echo "## k3s pvc (confirms no persistent-volume state)"
    kubectl get pvc -A 2>&1 || true
    echo
    echo "## docker containers"
    docker ps -a 2>&1 || true
} > "$WORK/MANIFEST.txt"
log "wrote MANIFEST.txt"

tar -czf "$OUT" -C "$WORK" .
chmod 600 "$OUT"
log "wrote $OUT ($(du -sh "$OUT" | cut -f1))"
log "contents:"
tar -tzf "$OUT"

log "done. Copy $OUT off-host (e.g. scp) before decommissioning this host."
