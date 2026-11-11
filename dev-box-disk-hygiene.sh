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
# Routine pass (timer, every 15 min). Each pass selects by explicit rules:
#   containers  exited/created/dead, no com.docker.compose.project label, name
#               matching no KEEP_CONTAINER_NAMES glob, stopped (State.FinishedAt;
#               Created for a container that never ran) longer than CONTAINER_MIN_AGE
#   volumes     dangling AND 64-hex (anonymous) AND older than VOLUME_MIN_AGE AND
#               not in the grace window of a container removed in the last
#               VOLUME_GRACE. Named volumes and volumes in use are never selected.
#   pytest      /tmp/pytest-of-<user>/pytest-N older than PYTEST_MIN_AGE, unreferenced
#   basetemps   pytest basetemp layout (numbered dirs plus a *current symlink) under
#               BASETEMP_ROOTS, depth <= BASETEMP_MAX_DEPTH, older than BASETEMP_MIN_AGE
#   releases    ~/.local/share/coding-gateway/releases/<40-hex>: keeps the release named
#               by the gateway unit, any a symlink points to, any a process references,
#               and the RELEASE_KEEP_NEWEST newest of the rest
#   images      docker image prune -f (dangling only, never -a)
# Removal is `docker rm` / `docker volume rm` on the ids selected above, never -f.
# Anonymous volumes of containers removed in a pass enter a grace window
# (volume-grace state file) before they become eligible.
#
# Free-space guard (timer, every 1 min). Marker and alert run first and never
# touch docker. A prune floor breach (percentage OR GiB, whichever trips first)
# starts a prune only if no other pass holds the lock and the last prune was at
# least PRUNE_MIN_INTERVAL ago. Every docker call is wrapped in a timeout.
#
# Never touches: containerd/k3s images, /var/lib/rancher, running containers,
# named volumes, git worktrees, or repo data.
#
# Usage:
#   bash dev-box-disk-hygiene.sh --dry-run          report every pass; changes nothing
#   bash dev-box-disk-hygiene.sh --install-user     ~/.local/bin + systemd USER timers
#   bash dev-box-disk-hygiene.sh --uninstall-user   remove the user timers, units, script
#   sudo bash dev-box-disk-hygiene.sh --install | --uninstall   system equivalents
#   dev-box-disk-hygiene --run | --guard            invoked by systemd

set -uo pipefail

# ---- configuration ----------------------------------------------------------
TAG=dev-box-disk-hygiene
ROOT_PREFIX=${DBDH_ROOT:-}              # test seam: rebases filesystem paths, skips root check
DOCKER_TIMEOUT=${DBDH_DOCKER_TIMEOUT:-60}
GUARD_PRUNE_BELOW_PCT=15
GUARD_PRUNE_BELOW_GB=40
GUARD_LOW_BELOW_PCT=10
GUARD_LOW_BELOW_GB=30
PRUNE_MIN_INTERVAL=$((10 * 60))
CONTAINER_MIN_AGE=$((24 * 3600))
VOLUME_MIN_AGE=$((2 * 3600))
VOLUME_GRACE=$((24 * 3600))
PYTEST_MIN_AGE=$((3 * 3600))
BASETEMP_MIN_AGE=$((24 * 3600))
BASETEMP_MAX_DEPTH=4
# Exact paths only. A glob is accepted only under $HOME (see root_entry_ok): /tmp is
# world-writable, so nothing may be expanded there.
BASETEMP_ROOTS=("$ROOT_PREFIX/tmp/claude-$(id -u)" "$HOME/.cache/wt-669/claude-local")
RELEASE_KEEP_NEWEST=2
# Stopped containers whose names match one of these globs are never removed.
KEEP_CONTAINER_NAMES=('kodus*' 'db_kodus_*' 'rabbitmq-prod' 'coding-gateway-*')
PYTEST_BASE=$ROOT_PREFIX/tmp/pytest-of-$(id -un)
GATEWAY_RELEASES=$HOME/.local/share/coding-gateway/releases
GATEWAY_UNIT=$HOME/.config/systemd/user/coding-gateway.service
SELF=$(readlink -f "${BASH_SOURCE[0]}")
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/dev-box-disk-hygiene
GRACE_FILE=$STATE_DIR/volume-grace
PRUNE_STAMP=$STATE_DIR/last-prune
if [[ -n "$ROOT_PREFIX" || $EUID -eq 0 ]]; then
    RUN_DIR=$ROOT_PREFIX/run
else
    RUN_DIR=${XDG_RUNTIME_DIR:-$HOME/.cache}
fi
MARKER=$RUN_DIR/dev-box-disk-low
LOCK=$RUN_DIR/dev-box-disk-hygiene.lock
REMOVED_THIS=0
declare -A REFUSED_BY=()
PROC_SNAP=""
PROC_SNAP_OK=0
PROC_SNAP_TAKEN=0

# ---- helpers ----------------------------------------------------------------
note() { logger -t "$TAG" -- "$*"; [[ -t 1 ]] && echo "$*"; return 0; }
warn() { logger -t "$TAG" -p daemon.warning -- "$*"; [[ -t 1 ]] && echo "$*" >&2; return 0; }

need_root() {
    [[ -n "$ROOT_PREFIX" || $EUID -eq 0 ]] || { echo "run as root (or use --install-user)" >&2; exit 1; }
}

# dk: every docker call goes through here, so a hung daemon cannot block a pass.
dk() { timeout "$DOCKER_TIMEOUT" docker "$@"; }

docker_up() {
    command -v docker >/dev/null 2>&1 && dk info >/dev/null 2>&1
}

gb() { awk -v b="$1" 'BEGIN { printf "%.1fGB", b / 1e9 }'; }

# root_free: "<pct-free> <GiB-free> <GiB-total>" for /, or nothing if unreadable.
root_free() {
    df -P / 2>/dev/null | awk 'NR == 2 && $2 > 0 { printf "%d %d %d\n", $4 * 100 / $2, $4 / 1048576, $2 / 1048576 }'
}

# older_than <stamp> <seconds>: true only when the stamp parses and is older.
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

# snapshot_procs: one read of every command line and every exe/cwd link.
# If the process list is unreadable, PROC_SNAP_OK stays 0 and everything counts as in use.
snapshot_procs() {
    local ps_out links
    if ps_out=$(ps -eo pid=,args= 2>/dev/null) && [[ -n "$ps_out" ]]; then
        links=$(find /proc/[0-9]*/exe /proc/[0-9]*/cwd -maxdepth 0 -printf '%l\n' 2>/dev/null)
        PROC_SNAP="$ps_out"$'\n'"$links"
        PROC_SNAP_OK=1
    fi
}

# ensure_snapshot: scan once per selector (each selector runs in its own subshell).
ensure_snapshot() {
    (( PROC_SNAP_TAKEN )) || { snapshot_procs; PROC_SNAP_TAKEN=1; }
}

# in_use <path>: a process references the path (command line, exe or cwd).
in_use() {
    ensure_snapshot
    (( PROC_SNAP_OK )) || return 0
    [[ "$PROC_SNAP" == *"$1"* ]]
}

dir_bytes() { du -sk -- "$1" 2>/dev/null | awk '{ printf "%d\n", $1 * 1024 }'; }

# owned_dir <path>: a real directory (not a symlink) owned by the current uid.
owned_dir() {
    [[ -d "$1" && ! -L "$1" ]] || return 1
    [[ "$(stat -c %u -- "$1" 2>/dev/null)" == "$(id -u)" ]]
}

# private_base <path>: owned by the current uid and not group/other-writable.
private_base() {
    local uid mode
    read -r uid mode < <(stat -c '%u %a' -- "$1" 2>/dev/null) || return 1
    [[ "$uid" == "$(id -u)" ]] && (( (8#$mode & 022) == 0 ))
}

# under <path> <parent>: the path's resolved parent is exactly the resolved parent dir.
under() {
    [[ "$(realpath -e -- "${1%/*}" 2>/dev/null)" == "$(realpath -e -- "$2" 2>/dev/null)" ]]
}

# root_entry_ok <entry>: an absolute exact path, or a glob that lies under $HOME.
root_entry_ok() {
    case $1 in
        *[*?[]*) [[ "$1" == "$HOME"/* ]] ;;
        *) [[ "$1" == /* ]] ;;
    esac
}

# chain_private <root> <dir>: every directory from <dir>'s parent up to <root>
# (inclusive) is owned by us and not group/other-writable. Root itself is checked
# by the caller with private_base.
chain_private() {
    local p=$2
    while :; do
        p=${p%/*}; [[ -n "$p" ]] || p=/
        private_base "$p" || return 1
        [[ "$p" == "$1" ]] && return 0
        [[ "$p" == / ]] && return 1
    done
}

# relax_ok <base> <dir>: the base is owned by us with mode exactly 0700, and every
# directory from <dir>'s parent down to the base is owned by us with no group/other
# access. Then no other user can reach the tree, so loose modes inside it are harmless.
relax_ok() {
    local p=${2%/*} uid ub mb u m
    uid=$(id -u)
    read -r ub mb < <(stat -c '%u %a' -- "$1" 2>/dev/null) || return 1
    [[ "$ub" == "$uid" && "$mb" == 700 ]] || return 1
    while [[ "$p" != "$1" ]]; do
        [[ "$p" == "$1"/* ]] || return 1
        read -r u m < <(stat -c '%u %a' -- "$p" 2>/dev/null) || return 1
        [[ "$u" == "$uid" && "$m" =~ ^[0-7]+$ ]] || return 1
        (( 8#$m & 077 )) && return 1
        p=${p%/*}
    done
    return 0
}

# remove_tree <dir> [relax]: delete a tree we own. The parent must be reached without
# a symlink; we cd into it and check pwd -P, then run every check and removal relative
# to it (./name), so a parent swapped after validation cannot redirect the deletion.
# Always refused: any entry owned by another uid. Refused unless relax=1: any directory
# that is group/other-writable. Returns 0 when removed; 1 unsafe path, 2 group/other-
# writable directory, 3 foreign-owned entry, 4 not ours or moved, 5 removal failed.
remove_tree() {
    local dir=$1 relax=${2:-0} parent name uid
    parent=${dir%/*}
    name=${dir##*/}
    uid=$(id -u)
    [[ -n "$name" && "$name" != . && "$name" != .. && "$parent" == /* ]] || return 1
    [[ "$(realpath -e -- "$parent" 2>/dev/null)" == "$parent" ]] || return 1
    (
        cd -- "$parent" || exit 4
        [[ "$(pwd -P)" == "$parent" ]] || exit 4
        [[ -d "./$name" && ! -L "./$name" && "$(stat -c %u -- "./$name" 2>/dev/null)" == "$uid" ]] || exit 4
        if (( ! relax )) && [[ -n "$(find -P "./$name" -xdev -type d -perm /022 -print -quit)" ]]; then
            exit 2
        fi
        [[ -z "$(find -P "./$name" -xdev ! -uid "$uid" -print -quit)" ]] || exit 3
        find -P "./$name" -xdev -type d ! -perm -u=w -execdir chmod u+w {} + \
            && find -P "./$name" -xdev -depth -delete || exit 5
    )
}

# refusal_reason <code>: the journal word for a remove_tree refusal.
refusal_reason() {
    case $1 in
        1) echo unsafe-path ;; 2) echo group-writable ;; 3) echo foreign-owner ;;
        4) echo not-ours ;; *) echo failed ;;
    esac
}

# record_refusal <code> <dir>: count one refused tree by reason and journal it.
record_refusal() {
    local why
    why=$(refusal_reason "$1")
    REFUSED_BY[$why]=$(( ${REFUSED_BY[$why]:-0} + 1 ))
    warn "refusing to remove $2: $why"
}

# ---- grace window for anonymous volumes of removed containers -----------------
# grace_record <volume>...: stamp volumes that a container removed in this pass used.
grace_record() {
    (( $# )) || return 0
    local now cut tmp n
    now=$(date +%s)
    cut=$((now - VOLUME_GRACE))
    mkdir -p "$STATE_DIR"
    tmp=$GRACE_FILE.new
    {
        [[ -f "$GRACE_FILE" ]] && awk -v c="$cut" '$2 >= c' "$GRACE_FILE"
        for n in "$@"; do printf '%s %s\n' "$n" "$now"; done
    } > "$tmp" && mv -f -- "$tmp" "$GRACE_FILE"
}

# grace_active <volume>: true when the volume was stamped within VOLUME_GRACE.
grace_active() {
    local n ts now
    [[ -f "$GRACE_FILE" ]] || return 1
    now=$(date +%s)
    while read -r n ts; do
        [[ "$n" == "$1" ]] && (( now - ts < VOLUME_GRACE )) && return 0
    done < "$GRACE_FILE"
    return 1
}

# ---- selectors: print "SEL<TAB>key<TAB>bytes<TAB>label", "KEEP<TAB>reason<TAB>item",
# "NA" (pass not applicable here, silent) or "ERR<TAB>message" (pass skipped, warned).

select_containers() {
    local id name state created labels stamp fin cre line
    local -a rows=() ids=()
    local -A finished=() created_of=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && rows+=("$line")
    done < <(dk ps -a --no-trunc --filter status=exited --filter status=created --filter status=dead \
        --format '{{.ID}}|{{.Names}}|{{.State}}|{{.CreatedAt}}|{{.Labels}}' 2>/dev/null)
    for line in "${rows[@]}"; do ids+=("${line%%|*}"); done
    (( ${#ids[@]} )) || return 0
    while IFS='|' read -r id fin cre _; do
        [[ -n "$id" ]] || continue
        finished[$id]=$fin
        created_of[$id]=$cre
    done < <(dk inspect -f '{{.Id}}|{{.State.FinishedAt}}|{{.Created}}|{{json .Mounts}}' "${ids[@]}" 2>/dev/null)
    for line in "${rows[@]}"; do
        IFS='|' read -r id name state created labels <<<"$line"
        stamp=${finished[$id]:-}
        [[ "$stamp" == 0001-* ]] && stamp=""           # never started: age from creation
        [[ -n "$stamp" ]] || stamp=${created_of[$id]:-}
        if [[ "$labels" == *com.docker.compose.project=* ]]; then
            printf 'KEEP\tcompose\t%s\n' "$name"
        elif keep_name "$name"; then
            printf 'KEEP\tkeep-pattern\t%s\n' "$name"
        elif [[ -z "$stamp" ]]; then
            printf 'KEEP\tunknown-age\t%s\n' "$name"
        elif ! older_than "$stamp" "$CONTAINER_MIN_AGE"; then
            printf 'KEEP\tstopped-recently\t%s\n' "$name"
        else
            printf 'SEL\t%s\t0\t%s\n' "$id" "$name"
        fi
    done
}

select_volumes() {
    local name created
    local -a anon=()
    local -A dangling=() size=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && dangling[$name]=1
    done < <(dk volume ls -q --filter dangling=true 2>/dev/null)
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ -z "${dangling[$name]:-}" ]]; then
            [[ "$name" =~ ^[0-9a-f]{64}$ ]] && printf 'KEEP\tin-use\t%s\n' "$name" || printf 'KEEP\tnamed-in-use\t%s\n' "$name"
        elif [[ "$name" =~ ^[0-9a-f]{64}$ ]]; then
            anon+=("$name")
        else
            printf 'KEEP\tnamed\t%s\n' "$name"
        fi
    done < <(dk volume ls -q 2>/dev/null)
    (( ${#anon[@]} )) || return 0
    while read -r name bytes; do
        size[$name]=$bytes
    done < <(dk system df -v 2>/dev/null | awk '
        function bytes(s,   n, u) { n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
            return n * (u == "kB" ? 1e3 : u == "MB" ? 1e6 : u == "GB" ? 1e9 : u == "TB" ? 1e12 : 1) }
        /^VOLUME NAME/ { f = 1; next } /^$/ { f = 0 }
        f && NF == 3 { print $1, bytes($3) }')
    while IFS='|' read -r name created; do
        [[ -n "$name" ]] || continue
        if grace_active "$name"; then
            printf 'KEEP\tgrace\t%s\n' "$name"
        elif older_than "$created" "$VOLUME_MIN_AGE"; then
            printf 'SEL\t%s\t%s\t%s\n' "$name" "${size[$name]:-0}" "$name"
        else
            printf 'KEEP\tyoung\t%s\n' "$name"
        fi
    done < <(dk volume inspect --format '{{.Name}}|{{.CreatedAt}}' "${anon[@]}" 2>/dev/null)
}

select_pytest() {
    [[ -d "$PYTEST_BASE" && ! -L "$PYTEST_BASE" ]] || { printf 'NA\n'; return 0; }
    if ! private_base "$PYTEST_BASE"; then
        printf 'ERR\t%s is not owned by %s or is group/other-writable\n' "$PYTEST_BASE" "$(id -un)"; return 0
    fi
    local d newest cutoff
    cutoff=$(( $(date +%s) - PYTEST_MIN_AGE ))
    for d in "$PYTEST_BASE"/pytest-[0-9]*; do
        owned_dir "$d" || { printf 'KEEP\tnot-owned-or-symlink\t%s\n' "$d"; continue; }
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

# basetemp_layout_ok <dir>: only numbered dirs (<prefix>N) and symlinks (<prefix>current),
# with each *current paired to a numbered sibling of the same prefix. Anything else fails.
basetemp_layout_ok() {
    local typ name p n matched
    local -a numbered=() currents=()
    while read -r typ name; do
        if [[ "$typ" == d && "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*[0-9]+$ ]]; then
            numbered+=("$name")
        elif [[ "$typ" == l && "$name" =~ ^([A-Za-z_][A-Za-z0-9_]*)current$ ]]; then
            currents+=("${BASH_REMATCH[1]}")
        else
            return 1
        fi
    done < <(find "$1" -mindepth 1 -maxdepth 1 -printf '%y %f\n' 2>/dev/null)
    (( ${#currents[@]} )) || return 1
    for p in "${currents[@]}"; do
        matched=0
        for n in "${numbered[@]}"; do
            [[ "$n" =~ ^${p}[0-9]+$ ]] && { matched=1; break; }
        done
        (( matched )) || return 1
    done
    return 0
}

select_basetemps() {
    local entry root d newest
    for entry in "${BASETEMP_ROOTS[@]}"; do
        if ! root_entry_ok "$entry"; then
            printf 'KEEP\tunsafe-root\t%s\n' "$entry"; continue
        fi
        for root in $entry; do                     # expands only for entries under $HOME
            [[ -d "$root" && ! -L "$root" ]] || continue
            if ! private_base "$root"; then
                printf 'KEEP\tunsafe-root\t%s\n' "$root"; continue
            fi
            while IFS= read -r d; do
                [[ -n "$d" ]] || continue
                basetemp_layout_ok "$d" || continue
                if ! owned_dir "$d" || ! chain_private "$root" "$d"; then
                    printf 'KEEP\tunsafe-ancestor\t%s\n' "$d"; continue
                fi
                newest=$(find "$d" -maxdepth 2 -printf '%T@\n' 2>/dev/null | sort -rn | head -n1 | cut -d. -f1)
                if [[ -z "$newest" ]] || (( newest >= $(date +%s) - BASETEMP_MIN_AGE )); then
                    printf 'KEEP\tyoung-or-unreadable\t%s\n' "$d"
                elif in_use "$d"; then
                    printf 'KEEP\tin-use\t%s\n' "$d"
                else
                    printf 'SEL\t%s\t%s\t%s\n' "$d" "$(dir_bytes "$d")" "$d"
                fi
            done < <(find "$root" -mindepth 1 -maxdepth "$BASETEMP_MAX_DEPTH" -type d 2>/dev/null)
        done
    done
}

select_releases() {
    [[ -d "$GATEWAY_RELEASES" && ! -L "$GATEWAY_RELEASES" ]] || { printf 'NA\n'; return 0; }
    owned_dir "$GATEWAY_RELEASES" || { printf 'ERR\t%s is not a directory owned by %s\n' "$GATEWAY_RELEASES" "$(id -un)"; return 0; }
    if [[ ! -f "$GATEWAY_UNIT" ]]; then
        printf 'ERR\t%s not found; active release unknown\n' "$GATEWAY_UNIT"; return 0
    fi
    local active linked mtime d id kept_newest=0 row link
    active=$(grep -oE '[0-9a-f]{40}' "$GATEWAY_UNIT" | sort -u)
    if [[ -z "$active" ]]; then
        printf 'ERR\tno release id referenced in %s\n' "$GATEWAY_UNIT"; return 0
    fi
    # Any symlink in the releases dir or its parent that resolves into the releases dir
    # (a `current` link, say) protects that release too.
    while IFS= read -r link; do
        [[ "$(dirname "$link")" == "$GATEWAY_RELEASES" ]] && active+=$'\n'"${link##*/}"
    done < <(find "$(dirname "$GATEWAY_RELEASES")" "$GATEWAY_RELEASES" -maxdepth 1 -type l -exec readlink -f {} + 2>/dev/null)
    while IFS= read -r row; do
        mtime=${row%% *}; d=${row#* }
        id=${d##*/}
        if [[ ! "$id" =~ ^[0-9a-f]{40}$ || "${d%/*}" != "$GATEWAY_RELEASES" ]]; then
            printf 'KEEP\tnot-a-release\t%s\n' "$d"
        elif grep -qx -- "$id" <<<"$active"; then
            printf 'KEEP\tactive\t%s\n' "$d"
        elif ! owned_dir "$d"; then
            printf 'KEEP\tnot-owned-or-symlink\t%s\n' "$d"
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
    local line names
    # Record the anonymous volumes these containers use BEFORE removing them, so the
    # volume pass in this same run leaves them alone for VOLUME_GRACE.
    names=$(dk inspect -f '{{json .Mounts}}' "$@" 2>/dev/null | grep -oE '"Name":"[0-9a-f]{64}"' | cut -d'"' -f4)
    # shellcheck disable=SC2086 # one volume name per word, all 64-hex
    grace_record $names
    while IFS= read -r line; do
        case $line in
            '') ;;
            Error*) warn "container rm: $line" ;;
            *) REMOVED_THIS=$((REMOVED_THIS + 1)); note "removed container $line" ;;
        esac
    done < <(dk rm -- "$@" 2>&1)
}

remove_volumes() {
    local line
    while IFS= read -r line; do
        case $line in
            '') ;;
            Error*) warn "volume rm: $line" ;;
            *) REMOVED_THIS=$((REMOVED_THIS + 1)); note "removed volume $line" ;;
        esac
    done < <(dk volume rm -- "$@" 2>&1)
}

remove_pytest_dirs() {
    local d relax
    for d in "$@"; do
        if ! under "$d" "$PYTEST_BASE" || [[ ! "${d##*/}" =~ ^pytest-[0-9]+$ ]] || ! owned_dir "$d"; then
            warn "refusing to remove $d (outside $PYTEST_BASE, not ours, or a symlink)"; continue
        fi
        relax=0; relax_ok "$PYTEST_BASE" "$d" && relax=1
        if remove_tree "$d" "$relax"; then
            REMOVED_THIS=$((REMOVED_THIS + 1)); note "removed pytest temp dir $d"
        else
            record_refusal "$?" "$d"
        fi
    done
}

# basetemp_root_of <dir>: the configured basetemp root that contains <dir>, if any.
basetemp_root_of() {
    local entry root
    for entry in "${BASETEMP_ROOTS[@]}"; do
        root_entry_ok "$entry" || continue
        for root in $entry; do
            [[ -d "$root" && "$1" == "$root"/* ]] && { printf '%s\n' "$root"; return 0; }
        done
    done
    return 1
}

remove_basetemps() {
    local d root relax
    for d in "$@"; do
        if ! owned_dir "$d" || ! basetemp_layout_ok "$d"; then
            warn "refusing to remove $d (not a basetemp or not ours)"; continue
        fi
        root=$(basetemp_root_of "$d") || root=
        relax=0; [[ -n "$root" ]] && relax_ok "$root" "$d" && relax=1
        if remove_tree "$d" "$relax"; then
            REMOVED_THIS=$((REMOVED_THIS + 1)); note "removed basetemp dir $d"
        else
            record_refusal "$?" "$d"
        fi
    done
}

remove_releases() {
    local d
    for d in "$@"; do
        if ! under "$d" "$GATEWAY_RELEASES" || [[ ! "${d##*/}" =~ ^[0-9a-f]{40}$ ]] || ! owned_dir "$d"; then
            warn "refusing to remove $d (not a release under $GATEWAY_RELEASES, not ours, or a symlink)"; continue
        fi
        if remove_tree "$d" 0; then
            REMOVED_THIS=$((REMOVED_THIS + 1)); note "removed gateway release ${d##*/}"
        else
            record_refusal "$?" "$d"
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
            KEEP)
                kept_by[$a]=$(( ${kept_by[$a]:-0} + 1 ))
                [[ $mode == run && $a == unsafe-* ]] && warn "$label kept $b ($a)"
                ;;
            NA) return 0 ;;
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
    REFUSED_BY=()
    for (( i = 0; i < n; i += 100 )); do
        "$remover" "${keys[@]:i:100}"
    done
    local refused=""
    for reason in "${!REFUSED_BY[@]}"; do refused+=" $reason=${REFUSED_BY[$reason]}"; done
    note "$label: removed $REMOVED_THIS of $n selected ($(gb "$total") planned); refused${refused:- none}"
    (( REMOVED_THIS == n )) || warn "$label: $((n - REMOVED_THIS)) selected item(s) not removed (in use or error)"
}

prune_images() {
    local out rc
    out=$(dk image prune -f 2>&1); rc=$?
    if (( rc != 0 )); then
        warn "images prune failed (rc=$rc): $(tail -1 <<<"$out")"
        return 1
    fi
    note "images: $(grep -i 'total reclaimed' <<<"$out" | tail -1 | sed 's/^ *//')"
}

# routine_pass <dry|run>: every pass, in dependency order (containers before volumes).
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
    if (( $(id -u) == 0 )); then
        # Never walk another user's /tmp or home as root: the user-level install does these.
        for label in pytest basetemps releases; do
            if [[ $mode == dry ]]; then
                echo "$label: skipped (running as root; use --install-user)"
            else
                note "$label pass skipped: running as root (use --install-user)"
            fi
        done
    else
        run_pass pytest select_pytest remove_pytest_dirs "$mode"
        run_pass basetemps select_basetemps remove_basetemps "$mode"
        run_pass releases select_releases remove_releases "$mode"
    fi
    if docker_up; then
        if [[ $mode == run ]]; then
            prune_images
        else
            echo "images: $(dk images -q -f dangling=true 2>/dev/null | sort -u | wc -l) dangling would be pruned (never -a)"
        fi
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

# take_prune_slot: true when this guard run may prune now: no other pass holds the
# lock and the last prune is at least PRUNE_MIN_INTERVAL old. Records the prune time.
take_prune_slot() {
    local now last
    mkdir -p "$(dirname "$LOCK")" "$STATE_DIR"
    exec 8>>"$LOCK"
    flock -n 8 || return 1
    now=$(date +%s)
    last=$(cat "$PRUNE_STAMP" 2>/dev/null)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now - last >= PRUNE_MIN_INTERVAL )) || return 1
    printf '%s\n' "$now" > "$PRUNE_STAMP"
}

# guard_pass: marker and alert first (never blocked by docker), then at most one prune.
guard_pass() {
    local reading pct gib total
    check_low_space
    reading=$(root_free)
    [[ -n "$reading" ]] || return 0
    read -r pct gib total <<<"$reading"
    (( pct < GUARD_PRUNE_BELOW_PCT || gib < GUARD_PRUNE_BELOW_GB )) || return 0
    warn "root free ${pct}% (${gib}GiB) below prune floor: pruning dev-box leftovers"
    if ! take_prune_slot; then
        note "prune skipped: another pass holds the lock or the last prune was under ${PRUNE_MIN_INTERVAL}s ago"
        return 0
    fi
    routine_pass run
}

# run_locked: a timer run waits (bounded) for a guard prune to finish, then runs.
run_locked() {
    mkdir -p "$(dirname "$LOCK")"
    exec 8>>"$LOCK"
    if ! flock -w 900 8; then
        note "skip: another pass held the lock for 15 minutes"
        return 0
    fi
    routine_pass run
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

# unit_paths <system|user>: sets bin, unit_dir and scope for the chosen install.
unit_paths() {
    if [[ $1 == user ]]; then
        bin=$HOME/.local/bin/$TAG
        unit_dir=$HOME/.config/systemd/user
        scope=(--user)
    else
        need_root
        bin=$ROOT_PREFIX/usr/local/bin/$TAG
        unit_dir=$ROOT_PREFIX/etc/systemd/system
        scope=()
    fi
}

install_units() {
    local bin unit_dir
    local -a scope
    unit_paths "$1"
    mkdir -p "$(dirname "$bin")" "$unit_dir"
    install -m 755 "$SELF" "$bin"

    cat > "$unit_dir/dev-box-disk-hygiene.service" <<UNIT
[Unit]
Description=Prune dev-box Docker and gateway leftovers (routine pass)

[Service]
Type=oneshot
ExecStart=$bin --run
TimeoutStartSec=15min
Nice=19
IOSchedulingClass=idle
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
Nice=19
IOSchedulingClass=idle
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

uninstall_units() {
    local bin unit_dir f
    local -a scope
    unit_paths "$1"
    systemctl "${scope[@]}" disable --now dev-box-disk-hygiene.timer dev-box-disk-hygiene-guard.timer || true
    for f in dev-box-disk-hygiene.service dev-box-disk-hygiene.timer \
             dev-box-disk-hygiene-guard.service dev-box-disk-hygiene-guard.timer; do
        rm -f -- "$unit_dir/$f"
    done
    rm -f -- "$bin"
    systemctl "${scope[@]}" daemon-reload
    echo "[dev-box-disk-hygiene] removed $bin and the $1 units"
}

main() {
    case "${1:-}" in
        --dry-run) dry_run ;;
        --install) install_units system ;;
        --install-user) install_units user ;;
        --uninstall) uninstall_units system ;;
        --uninstall-user) uninstall_units user ;;
        --run) run_locked ;;
        --guard) guard_pass ;;
        *)
            echo "usage: $0 --dry-run | --install-user | --uninstall-user | --install | --uninstall | --run | --guard" >&2
            exit 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
