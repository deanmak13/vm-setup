#!/usr/bin/env bash
# dev-box-disk-hygiene.sh - keep test and gateway leftovers from filling the dev
# box's root disk. The dev box is also the single TST k3s node, so a full root
# disk means kubelet disk-pressure: pods evicted, replacements Pending under the
# node.kubernetes.io/disk-pressure taint, all of TST down.
#
# 2026-10-24 incident: 1,296 dangling Docker volumes (62GB) left by throwaway
# test Postgres containers. pgvector/pgvector:pg16 declares a VOLUME, and
# containers killed by timeouts or started without --rm leak anonymous volumes.
# 2026-11-11 incident: 1,291 anonymous volumes (56.6GB), 71 superseded gateway
# releases (29GB), pytest temp trees at 1-4GB per gate run, 17 stopped test
# containers. Two disk-pressure events; ~100GB reclaimed by hand.
#
# Routine pass (timer, every 15 min). Each pass selects by explicit rules and
# never by a blanket prune:
#   containers  exited/created/dead, no com.docker.compose.project label, name
#               matching no KEEP_CONTAINER_NAMES glob, older than CONTAINER_MIN_AGE
#   volumes     dangling AND 64-hex (anonymous) AND older than VOLUME_MIN_AGE;
#               named volumes and volumes in use are never selected
#   pytest      /tmp/pytest-of-<user>/pytest-N directories whose
#               newest entry (depth <= 2) is older than PYTEST_MIN_AGE and that
#               no process references; pytest-current is not a candidate
#   releases    ~/.local/share/coding-gateway/releases/<40-hex>: keeps the release
#               named by the coding-gateway unit, any referenced by a process, and
#               the RELEASE_KEEP_NEWEST newest of the rest
#   images      docker image prune -f (dangling only, never -a)
# Container and volume removal is `docker rm` / `docker volume rm` on the ids
# selected above; neither is -f, so a container that started meanwhile is refused.
#
# Free-space guard (timer, every 1 min) on the root filesystem. A floor is
# breached when the percentage OR the absolute GiB threshold trips first:
#   prune  below GUARD_PRUNE_BELOW_PCT / GUARD_PRUNE_BELOW_GB: WARNING to the
#          journal (daemon.warning) + immediate routine pass
#   low    below GUARD_LOW_BELOW_PCT / GUARD_LOW_BELOW_GB: marker file (test
#          tooling checks it) and a daemon.warning alert on entry. This is the
#          same channel zombie-monitor uses. The marker is removed once clear.
#
# Never touches: containerd/k3s images, /var/lib/rancher, running containers,
# named volumes, git worktrees, or repo data. The script has no git, ctr,
# crictl or rancher calls.
#
# Usage:
#   bash dev-box-disk-hygiene.sh --dry-run        report every pass (counts, sizes); changes nothing
#   bash dev-box-disk-hygiene.sh --install-user   install to ~/.local/bin and enable systemd USER timers
#   sudo bash dev-box-disk-hygiene.sh --install   install to /usr/local/bin and enable system timers
#   dev-box-disk-hygiene --run | --guard          invoked by systemd

set -uo pipefail

# ---- configuration ----------------------------------------------------------
TAG=dev-box-disk-hygiene
ROOT_PREFIX=${DBDH_ROOT:-}       # test seam: rebases filesystem paths, skips root check
GUARD_PRUNE_BELOW_PCT=15
GUARD_PRUNE_BELOW_GB=40
GUARD_LOW_BELOW_PCT=10
GUARD_LOW_BELOW_GB=30
CONTAINER_MIN_AGE=$((6 * 3600))
VOLUME_MIN_AGE=$((2 * 3600))
PYTEST_MIN_AGE=$((3 * 3600))
RELEASE_KEEP_NEWEST=2
# Stopped containers whose names match one of these globs are never removed.
KEEP_CONTAINER_NAMES=('kodus*' 'db_kodus_*' 'rabbitmq-prod' 'coding-gateway-*')
PYTEST_BASE=$ROOT_PREFIX/tmp/pytest-of-$(id -un)
GATEWAY_RELEASES=$HOME/.local/share/coding-gateway/releases
GATEWAY_UNIT=$HOME/.config/systemd/user/coding-gateway.service
SELF=$(readlink -f "$0")
if [[ -n "$ROOT_PREFIX" || $EUID -eq 0 ]]; then
    MARKER=$ROOT_PREFIX/run/dev-box-disk-low
else
    MARKER=${XDG_RUNTIME_DIR:-$HOME/.cache}/dev-box-disk-low
fi
REMOVED_THIS=0

# ---- helpers ----------------------------------------------------------------
note() { logger -t "$TAG" -- "$*"; [[ -t 1 ]] && echo "$*"; return 0; }
warn() { logger -t "$TAG" -p daemon.warning -- "$*"; [[ -t 1 ]] && echo "$*" >&2; return 0; }

need_root() {
    [[ -n "$ROOT_PREFIX" || $EUID -eq 0 ]] || { echo "run as root (or use --install-user)" >&2; exit 1; }
}

gb() { awk -v b="$1" 'BEGIN { printf "%.1fGB", b / 1e9 }'; }

# root_free: "<pct-free> <GiB-free> <GiB-total>" for /, or nothing if unreadable.
root_free() {
    df -P / 2>/dev/null | awk 'NR == 2 && $2 > 0 { printf "%d %d %d\n", $4 * 100 / $2, $4 / 1048576, $2 / 1048576 }'
}

docker_up() {
    command -v docker >/dev/null 2>&1 && timeout 20 docker info >/dev/null 2>&1
}

# older_than <docker-or-rfc3339 stamp> <seconds>: true only when parseable and older.
older_than() {
    local ts
    [[ -n "$1" ]] || return 1
    ts=$(date -d "${1% UTC}" +%s 2>/dev/null) || return 1
    (( ts < $(date +%s) - $2 ))
}

# keep_name <name>: true when the name matches a KEEP_CONTAINER_NAMES glob.
keep_name() {
    local pat
    for pat in "${KEEP_CONTAINER_NAMES[@]}"; do
        # shellcheck disable=SC2053 # the patterns are globs on purpose
        [[ "$1" == $pat ]] && return 0
    done
    return 1
}

# in_use <path>: a process has the path in its cmdline, or its exe or cwd is under it.
in_use() {
    local p link target
    pgrep -f "$1" >/dev/null 2>&1 && return 0
    for p in /proc/[0-9]*; do
        for link in exe cwd; do
            target=$(readlink "$p/$link" 2>/dev/null) || continue
            [[ "$target" == "$1"* ]] && return 0
        done
    done
    return 1
}

dir_bytes() { du -sk -- "$1" 2>/dev/null | awk '{ printf "%d\n", $1 * 1024 }'; }

# ---- selectors: print "SEL<TAB>key<TAB>bytes<TAB>label", "KEEP<TAB>reason<TAB>item", "NA" (not applicable) or "ERR<TAB>message"

select_containers() {
    local id name state created labels
    while IFS='|' read -r id name state created labels; do
        [[ -n "$id" ]] || continue
        if [[ "$labels" == *com.docker.compose.project=* ]]; then
            printf 'KEEP\tcompose\t%s\n' "$name"
        elif keep_name "$name"; then
            printf 'KEEP\tkeep-pattern\t%s\n' "$name"
        elif ! older_than "$created" "$CONTAINER_MIN_AGE"; then
            printf 'KEEP\tyoung-or-unknown\t%s\n' "$name"
        else
            printf 'SEL\t%s\t0\t%s\n' "$id" "$name"
        fi
    done < <(docker ps -a --no-trunc --filter status=exited --filter status=created --filter status=dead \
        --format '{{.ID}}|{{.Names}}|{{.State}}|{{.CreatedAt}}|{{.Labels}}' 2>/dev/null)
}

select_volumes() {
    local name created
    local -a anon=()
    local -A dangling=() size=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && dangling[$name]=1
    done < <(docker volume ls -q --filter dangling=true 2>/dev/null)
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ -z "${dangling[$name]:-}" ]]; then
            [[ "$name" =~ ^[0-9a-f]{64}$ ]] && printf 'KEEP\tin-use\t%s\n' "$name" || printf 'KEEP\tnamed-in-use\t%s\n' "$name"
        elif [[ "$name" =~ ^[0-9a-f]{64}$ ]]; then
            anon+=("$name")
        else
            printf 'KEEP\tnamed\t%s\n' "$name"
        fi
    done < <(docker volume ls -q 2>/dev/null)
    (( ${#anon[@]} )) || return 0
    while read -r name bytes; do
        size[$name]=$bytes
    done < <(docker system df -v 2>/dev/null | awk '
        function bytes(s,   n, u) { n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
            return n * (u == "kB" ? 1e3 : u == "MB" ? 1e6 : u == "GB" ? 1e9 : u == "TB" ? 1e12 : 1) }
        /^VOLUME NAME/ { f = 1; next } /^$/ { f = 0 }
        f && NF == 3 { print $1, bytes($3) }')
    while IFS='|' read -r name created; do
        [[ -n "$name" ]] || continue
        if older_than "$created" "$VOLUME_MIN_AGE"; then
            printf 'SEL\t%s\t%s\t%s\n' "$name" "${size[$name]:-0}" "$name"
        else
            printf 'KEEP\tyoung\t%s\n' "$name"
        fi
    done < <(docker volume inspect --format '{{.Name}}|{{.CreatedAt}}' "${anon[@]}" 2>/dev/null)
}

select_pytest() {
    [[ -d "$PYTEST_BASE" && ! -L "$PYTEST_BASE" ]] || { printf 'NA\n'; return 0; }
    local d newest cutoff
    cutoff=$(( $(date +%s) - PYTEST_MIN_AGE ))
    for d in "$PYTEST_BASE"/pytest-[0-9]*; do
        [[ -d "$d" && ! -L "$d" ]] || continue
        newest=$(find "$d" -maxdepth 2 -printf '%T@\n' 2>/dev/null | sort -rn | head -n1 | cut -d. -f1)
        if [[ -z "$newest" ]] || (( newest >= cutoff )); then
            printf 'KEEP\tyoung-or-unreadable\t%s\n' "$d"
        elif in_use "$d"; then
            printf 'KEEP\tin-use\t%s\n' "$d"
        else
            printf 'SEL\t%s\t%s\t%s\n' "$d" "$(dir_bytes "$d")" "$d"
        fi
    done
}

select_releases() {
    [[ -d "$GATEWAY_RELEASES" && ! -L "$GATEWAY_RELEASES" ]] || { printf 'NA\n'; return 0; }
    if [[ ! -f "$GATEWAY_UNIT" ]]; then
        printf 'ERR\t%s not found; active release unknown\n' "$GATEWAY_UNIT"; return 0
    fi
    local active mtime d id kept_newest=0 row
    active=$(grep -oE '[0-9a-f]{40}' "$GATEWAY_UNIT" | sort -u)
    if [[ -z "$active" ]]; then
        printf 'ERR\tno release id referenced in %s\n' "$GATEWAY_UNIT"; return 0
    fi
    while IFS= read -r row; do
        mtime=${row%% *}; d=${row#* }
        id=${d##*/}
        if [[ ! "$id" =~ ^[0-9a-f]{40}$ || "${d%/*}" != "$GATEWAY_RELEASES" ]]; then
            printf 'KEEP\tnot-a-release\t%s\n' "$d"
        elif grep -qx -- "$id" <<<"$active"; then
            printf 'KEEP\tactive\t%s\n' "$d"
        elif in_use "$d"; then
            printf 'KEEP\tin-use\t%s\n' "$d"
        elif (( kept_newest < RELEASE_KEEP_NEWEST )); then
            kept_newest=$((kept_newest + 1))
            printf 'KEEP\tnewest-%s\t%s\n' "$RELEASE_KEEP_NEWEST" "$d"
        else
            printf 'SEL\t%s\t%s\t%s\n' "$d" "$(dir_bytes "$d")" "$d"
        fi
    done < <(find "$GATEWAY_RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn)
}

# ---- removers: act on the ids/paths a selector returned; count into REMOVED_THIS

remove_containers() {
    local line
    while IFS= read -r line; do
        case $line in
            '') ;;
            Error*) warn "container rm: $line" ;;
            *) REMOVED_THIS=$((REMOVED_THIS + 1)); note "removed container $line" ;;
        esac
    done < <(timeout 600 docker rm -- "$@" 2>&1)
}

remove_volumes() {
    local line
    while IFS= read -r line; do
        case $line in
            '') ;;
            Error*) warn "volume rm: $line" ;;
            *) REMOVED_THIS=$((REMOVED_THIS + 1)); note "removed volume $line" ;;
        esac
    done < <(timeout 600 docker volume rm -- "$@" 2>&1)
}

remove_pytest_dirs() {
    local d
    for d in "$@"; do
        if [[ "${d%/*}" != "$PYTEST_BASE" || ! "${d##*/}" =~ ^pytest-[0-9]+$ || -L "$d" || ! -d "$d" ]]; then
            warn "refusing to remove $d (outside $PYTEST_BASE)"; continue
        fi
        if rm -rf -- "$d"; then
            REMOVED_THIS=$((REMOVED_THIS + 1)); note "removed pytest temp dir $d"
        else
            warn "could not remove pytest temp dir $d"
        fi
    done
}

remove_releases() {
    local d
    for d in "$@"; do
        if [[ "${d%/*}" != "$GATEWAY_RELEASES" || ! "${d##*/}" =~ ^[0-9a-f]{40}$ || -L "$d" || ! -d "$d" ]]; then
            warn "refusing to remove $d (not a release under $GATEWAY_RELEASES)"; continue
        fi
        # Release trees are stored read-only: restore owner write before removing.
        if chmod -R u+w -- "$d" && rm -rf -- "$d"; then
            REMOVED_THIS=$((REMOVED_THIS + 1)); note "removed gateway release ${d##*/}"
        else
            warn "could not remove gateway release ${d##*/}"
        fi
    done
}

# run_pass <label> <selector> <remover> <dry|run>: select, then report or remove in batches of 100.
run_pass() {
    local label=$1 selector=$2 remover=$3 mode=$4
    local verdict a b c total=0 n i reason kept=""
    local -a keys=() shown=()
    local -A kept_by=()
    local selection
    selection=$("$selector")
    while IFS=$'\t' read -r verdict a b c; do
        case $verdict in
            SEL) keys+=("$a"); total=$((total + b)); shown+=("$c") ;;
            KEEP) kept_by[$a]=$(( ${kept_by[$a]:-0} + 1 )) ;;
            NA) return 0 ;;   # pass not applicable on this box: silent
            ERR)
                if [[ $mode == dry ]]; then echo "$label: skipped ($a)"; else warn "$label pass skipped: $a"; fi
                return 0 ;;
        esac
    done <<<"$selection"
    n=${#keys[@]}
    for reason in "${!kept_by[@]}"; do kept+=" $reason=${kept_by[$reason]}"; done
    if [[ $mode == dry ]]; then
        printf '%s: %d would be removed (%s);%s\n' "$label" "$n" "$(gb "$total")" "${kept:- kept none}"
        if (( n > 0 && n <= 25 )); then printf '  %s\n' "${shown[@]}"; fi
        return 0
    fi
    (( n > 0 )) || return 0
    REMOVED_THIS=0
    for (( i = 0; i < n; i += 100 )); do
        "$remover" "${keys[@]:i:100}"
    done
    note "$label: removed $REMOVED_THIS of $n selected ($(gb "$total") planned)"
    (( REMOVED_THIS == n )) || warn "$label: $((n - REMOVED_THIS)) selected item(s) not removed (in use or error)"
}

prune_images() {
    local out rc
    out=$(timeout 600 docker image prune -f 2>&1); rc=$?
    if (( rc != 0 )); then
        warn "images prune failed (rc=$rc): $(tail -1 <<<"$out")"
        return 1
    fi
    note "images: $(grep -i 'total reclaimed' <<<"$out" | tail -1 | sed 's/^ *//')"
}

# routine_pass <dry|run>: every pass, in dependency order (containers before volumes,
# so the anonymous volumes they leave behind are selected by the volume pass).
routine_pass() {
    local mode=$1
    if docker_up; then
        run_pass containers select_containers remove_containers "$mode"
        run_pass volumes select_volumes remove_volumes "$mode"
    elif [[ $mode == dry ]]; then
        echo "containers and volumes: docker daemon not reachable; nothing to report"
    else
        note "skip: docker daemon not reachable"
    fi
    run_pass pytest select_pytest remove_pytest_dirs "$mode"
    run_pass releases select_releases remove_releases "$mode"
    if [[ $mode == run ]] && docker_up; then
        prune_images
    elif [[ $mode == dry ]] && docker_up; then
        echo "images: $(docker images -q -f dangling=true 2>/dev/null | sort -u | wc -l) dangling would be pruned (never -a)"
    fi
}

check_low_space() {
    local reading pct gib total
    reading=$(root_free)
    if [[ -z "$reading" ]]; then
        warn "cannot read root free space"
        return 1
    fi
    read -r pct gib total <<<"$reading"
    if (( pct < GUARD_LOW_BELOW_PCT || gib < GUARD_LOW_BELOW_GB )); then
        [[ -e "$MARKER" ]] || warn "root free ${pct}% (${gib}GiB) below low-space floor: dev-box disk LOW, TST disk-pressure risk (marker $MARKER)"
        mkdir -p "$(dirname "$MARKER")"
        date -Is > "$MARKER"
    else
        rm -f -- "$MARKER"
    fi
}

guard_pass() {
    local reading pct gib total
    reading=$(root_free)
    if [[ -n "$reading" ]]; then
        read -r pct gib total <<<"$reading"
        if (( pct < GUARD_PRUNE_BELOW_PCT || gib < GUARD_PRUNE_BELOW_GB )); then
            warn "root free ${pct}% (${gib}GiB) below prune floor: pruning dev-box leftovers now"
            routine_pass run
        fi
    fi
    check_low_space
}

dry_run() {
    local reading pct gib total
    reading=$(root_free)
    if [[ -n "$reading" ]]; then
        read -r pct gib total <<<"$reading"
        echo "root free: ${pct}% (${gib} GiB of ${total} GiB)  guard: prune below ${GUARD_PRUNE_BELOW_PCT}% or ${GUARD_PRUNE_BELOW_GB} GiB; marker below ${GUARD_LOW_BELOW_PCT}% or ${GUARD_LOW_BELOW_GB} GiB"
    else
        echo "root free: unknown"
    fi
    routine_pass dry
    echo "dry run: nothing was changed"
}

# install_units <system|user>: copy the script, write the four units, enable both timers.
install_units() {
    local bin unit_dir
    local -a scope=()
    if [[ $1 == user ]]; then
        bin=$HOME/.local/bin/$TAG
        unit_dir=$HOME/.config/systemd/user
        scope=(--user)
    else
        need_root
        bin=$ROOT_PREFIX/usr/local/bin/$TAG
        unit_dir=$ROOT_PREFIX/etc/systemd/system
    fi
    mkdir -p "$(dirname "$bin")" "$unit_dir"
    install -m 755 "$SELF" "$bin"

    cat > "$unit_dir/dev-box-disk-hygiene.service" <<UNIT
[Unit]
Description=Prune dev-box Docker and gateway leftovers (routine pass)

[Service]
Type=oneshot
ExecStart=$bin --run
TimeoutStartSec=15min
UNIT

    cat > "$unit_dir/dev-box-disk-hygiene.timer" <<'UNIT'
[Unit]
Description=Run dev-box-disk-hygiene every 15 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
UNIT

    cat > "$unit_dir/dev-box-disk-hygiene-guard.service" <<UNIT
[Unit]
Description=Dev-box root free-space guard

[Service]
Type=oneshot
ExecStart=$bin --guard
TimeoutStartSec=10min
UNIT

    cat > "$unit_dir/dev-box-disk-hygiene-guard.timer" <<'UNIT'
[Unit]
Description=Run the dev-box free-space guard every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
UNIT

    systemctl "${scope[@]}" daemon-reload
    systemctl "${scope[@]}" enable --now dev-box-disk-hygiene.timer dev-box-disk-hygiene-guard.timer
    echo "[dev-box-disk-hygiene] installed $bin and $1 timers (routine 15min, guard 1min)"

    if [[ $1 == user ]]; then
        local owner linger
        owner=$(id -un)
        linger=$(loginctl show-user "$owner" -p Linger --value 2>/dev/null)
        if [[ "$linger" == yes ]]; then
            echo "[dev-box-disk-hygiene] lingering is on for $owner: timers run without a login session"
        else
            echo "[dev-box-disk-hygiene] lingering is OFF for $owner: the timers stop when no session is open."
            echo "  owner runs once: sudo loginctl enable-linger $owner"
        fi
    fi
}

case "${1:-}" in
    --dry-run) dry_run ;;
    --install) install_units system ;;
    --install-user) install_units user ;;
    --run)
        routine_pass run
        check_low_space
        ;;
    --guard) guard_pass ;;
    *)
        echo "usage: $0 --dry-run | --install-user | --install | --run | --guard" >&2
        exit 2
        ;;
esac
