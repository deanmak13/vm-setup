#!/usr/bin/env bash
# dev-box-disk-hygiene.sh — Keep Docker leftovers from filling the dev box's
# root disk. The dev box is also the single TST k3s node, so a full root disk
# means kubelet disk-pressure: pods evicted, replacements Pending under the
# node.kubernetes.io/disk-pressure taint, all of TST down.
#
# 2026-10-24 incident: 1,296 dangling Docker volumes (62GB) left by throwaway
# test Postgres containers. pgvector/pgvector:pg16 declares a VOLUME, and
# containers killed by timeouts or started without --rm leak anonymous volumes.
#
# Routine pass (timer, every 15 min), in this order:
#   1. docker container prune -f --filter until=6h   exited/created containers only
#   2. docker volume prune -f                        unused volumes only (never -a)
#   3. docker image prune -f                         dangling images only (never -a)
#      Containers go first so the anonymous volumes they leave behind become
#      unused and get reclaimed by step 2.
#
# Free-space guard (timer, every 1 min) on the root filesystem:
#   free < 15%  WARNING to the journal (daemon.warning) + immediate routine pass
#   free < 10%  marker file /run/dev-box-disk-low (test tooling checks it), and a
#               daemon.warning syslog alert on entry. This is the same channel
#               zombie-monitor uses (logger -p daemon.warning).
#   The marker is removed once free >= 10%.
#
# Never touches: containerd/k3s images, /var/lib/rancher, running containers,
# git worktrees, or any repo data. It only calls the three docker prune
# subcommands above, which skip running containers and volumes still in use.
#
# Usage:
#   bash dev-box-disk-hygiene.sh --dry-run          report what a pass would reclaim (no changes)
#   sudo bash dev-box-disk-hygiene.sh --install     copy to /usr/local/bin and install the timers
#   sudo dev-box-disk-hygiene --run | --guard       invoked by systemd

set -uo pipefail

BIN=/usr/local/bin/dev-box-disk-hygiene
MARKER=/run/dev-box-disk-low
TAG=dev-box-disk-hygiene
GUARD_PRUNE_BELOW=15   # root free % that triggers a WARNING and an immediate prune
GUARD_LOW_BELOW=10     # root free % that writes the marker and alerts
SELF=$(readlink -f "$0")

note() { logger -t "$TAG" -- "$*"; [[ -t 1 ]] && echo "$*"; return 0; }
warn() { logger -t "$TAG" -p daemon.warning -- "$*"; [[ -t 1 ]] && echo "$*"; return 0; }

root_free_pct() {
    df -P / 2>/dev/null | awk 'NR == 2 && $2 > 0 { print int($4 * 100 / $2) }'
}

docker_up() {
    command -v docker >/dev/null 2>&1 && timeout 20 docker info >/dev/null 2>&1
}

# prune_step <label> <docker args...>: run one prune and journal what it reclaimed.
prune_step() {
    local label=$1; shift
    local out rc
    out=$(timeout 600 docker "$@" 2>&1)
    rc=$?
    if (( rc != 0 )); then
        warn "$label prune failed (rc=$rc): $(tail -1 <<<"$out")"
        return 1
    fi
    note "$label: $(grep -i 'total reclaimed' <<<"$out" | tail -1 | sed 's/^ *//')"
}

routine_pass() {
    docker_up || { note "skip: docker daemon not reachable"; return 0; }
    prune_step containers container prune -f --filter until=6h
    prune_step volumes volume prune -f
    prune_step images image prune -f
}

check_low_space() {
    local free
    free=$(root_free_pct)
    if [[ -z "$free" ]]; then
        warn "cannot read root free space"
        return 1
    fi
    if (( free < GUARD_LOW_BELOW )); then
        [[ -e "$MARKER" ]] || warn "root free ${free}% < ${GUARD_LOW_BELOW}%: dev-box disk LOW, TST disk-pressure risk (marker $MARKER)"
        date -Is > "$MARKER"
    else
        rm -f "$MARKER"
    fi
}

guard_pass() {
    local free
    free=$(root_free_pct)
    if [[ -n "$free" ]] && (( free < GUARD_PRUNE_BELOW )); then
        warn "root free ${free}% < ${GUARD_PRUNE_BELOW}%: pruning dev-box Docker leftovers now"
        routine_pass
    fi
    check_low_space
}

dry_run() {
    local free
    free=$(root_free_pct)
    echo "root free: ${free:-unknown}%  (guard: prune below ${GUARD_PRUNE_BELOW}%, marker below ${GUARD_LOW_BELOW}%)"
    docker_up || { echo "docker daemon not reachable; nothing to report"; return 0; }

    # LINKS = containers referencing the volume. Zero links = prune candidate.
    docker system df -v | awk '
        function bytes(s,   n, u) {
            n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
            if (u == "kB") return n * 1e3
            if (u == "MB") return n * 1e6
            if (u == "GB") return n * 1e9
            if (u == "TB") return n * 1e12
            return n
        }
        /^VOLUME NAME/ { f = 1; next }
        /^$/ { f = 0 }
        f && NF == 3 { if ($2 == 0) { cand++; sum += bytes($3) } else { kept++ } }
        END {
            printf "volumes: %d unused would be pruned (%.1fGB); %d in use kept\n", cand + 0, sum / 1e9, kept + 0
        }'

    local cutoff stale=0 id ts
    cutoff=$(date -d '6 hours ago' +%s)
    while read -r id ts; do
        [[ -n "$id" ]] || continue
        (( $(date -d "$ts" +%s) < cutoff )) && stale=$((stale + 1))
    done < <(docker ps -aq --filter status=exited --filter status=created --filter status=dead \
        | xargs -r docker inspect -f '{{.Id}} {{.Created}}')
    echo "containers: ${stale} exited/created older than 6h would be pruned"

    echo "images: $(docker images -q -f dangling=true | sort -u | wc -l) dangling would be pruned (never -a)"
    echo "dry run: nothing was changed"
}

install_units() {
    [[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $SELF --install" >&2; exit 1; }
    install -m 755 "$SELF" "$BIN"

    cat > /etc/systemd/system/dev-box-disk-hygiene.service <<UNIT
[Unit]
Description=Prune dev-box Docker leftovers (routine pass)

[Service]
Type=oneshot
ExecStart=$BIN --run
TimeoutStartSec=15min
UNIT

    cat > /etc/systemd/system/dev-box-disk-hygiene.timer <<'UNIT'
[Unit]
Description=Run dev-box-disk-hygiene every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
UNIT

    cat > /etc/systemd/system/dev-box-disk-hygiene-guard.service <<UNIT
[Unit]
Description=Dev-box root free-space guard

[Service]
Type=oneshot
ExecStart=$BIN --guard
TimeoutStartSec=10min
UNIT

    cat > /etc/systemd/system/dev-box-disk-hygiene-guard.timer <<'UNIT'
[Unit]
Description=Run the dev-box free-space guard every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable --now dev-box-disk-hygiene.timer dev-box-disk-hygiene-guard.timer
    echo "[dev-box-disk-hygiene] installed $BIN and timers (routine 15min, guard 1min)"
}

case "${1:-}" in
    --dry-run) dry_run ;;
    --install) install_units ;;
    --run | --guard)
        [[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
        if [[ "$1" == "--run" ]]; then
            routine_pass
            check_low_space
        else
            guard_pass
        fi
        ;;
    *)
        echo "usage: $0 --dry-run | --install | --run | --guard" >&2
        exit 2
        ;;
esac
