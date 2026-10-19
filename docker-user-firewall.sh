#!/usr/bin/env bash
# docker-user-firewall.sh -- block PUBLIC inbound to Docker-published ports by default.
#
# Docker publishes ports via DNAT in nat/PREROUTING, so they bypass INPUT and any host
# firewall. Traffic to containers traverses FORWARD -> DOCKER-USER, the only hook Docker
# leaves to operators. This script owns one sub-chain (PNEUMA-DOCKER-FW) that is always the
# FIRST rule of DOCKER-USER, for IPv4 and IPv6. It never edits INPUT/FORWARD policy, k3s
# chains or Docker's own chains.
#
# Chain semantics (default DROP; the external interface is never named, so every public
# interface, route layout or custom/gateway bridge is covered):
#   1. ESTABLISHED,RELATED                         -> RETURN
#   2. arrives on a trusted interface              -> RETURN  (lo, docker bridges, CNI, wg0)
#   3. leaves through a k3s interface (cni0/flannel.1)  -> RETURN  (k3s owns that traffic)
#   4. DNAT'd traffic to an allowlisted HOST port  -> RETURN  (conntrack state DNAT + original
#      dst port, so a direct hit on a container IP is NOT allowlisted)
#   5. everything else                             -> DROP
#
# Host role comes ONLY from the root-owned declarative file /etc/pneuma/host-role (0644
# root:root, written by the vm-setup bootstrap / --install). --role is honoured for
# --dry-run/--render/--install only. FAIL CLOSED: a missing/invalid role file, a missing or
# invalid allowlist (strict grammar, no wildcards) or a failed load installs the built-in
# baseline (trusted interfaces only, no public ports) and exits non-zero. Rules load
# atomically with iptables-restore; a failed load leaves the previous ruleset untouched.
#
# Usage: docker-user-firewall.sh [--role R] MODE
#   --dry-run (default)   print the rules/commands and validate loadability (iptables-restore --test)
#   --render              print only the rule body
#   --apply [--pre-docker] [--rollback-timer SECONDS]
#                         apply v4+v6 and verify; --pre-docker skips the FORWARD-jump check and every
#                         Docker CLI query (boot, before docker.service: docker.sock cannot answer yet);
#                         the timer schedules --remove after SECONDS
#   --confirm             cancel the rollback timer and start the reconcile timer
#   --verify              check jump-first + FORWARD->DOCKER-USER + DROP in v4 and v6 (exit code)
#   --reconcile           --verify; re-apply when it fails (run by a timer and after docker start)
#   --remove              remove jump and chain (rollback); reports accurately
#   --install             install script, allowlist, units, docker drop-in and write the role file
# One-liners: sudo bash <path> --role <role> --dry-run | --role <role> --install | --apply --rollback-timer 300
# Env (tests): DOCKER_FW_ALLOWLIST, DOCKER_FW_ROLE_FILE, DOCKER_FW_ROLE_UID, DOCKER_FW_IPTABLES*, DOCKER_FW_IP6TABLES*
set -uo pipefail

CHAIN="PNEUMA-DOCKER-FW"
ROLE_FILE="${DOCKER_FW_ROLE_FILE:-/etc/pneuma/host-role}"
ROLE_UID="${DOCKER_FW_ROLE_UID:-0}"
INSTALL_DIR=/usr/local/lib/pneuma-docker-fw
ROLLBACK_UNIT=docker-fw-rollback
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
ALLOWLIST="${DOCKER_FW_ALLOWLIST:-$HERE/docker-user-firewall.allowlist}"
IPT4="${DOCKER_FW_IPTABLES:-iptables}"
IPT4_RESTORE="${DOCKER_FW_IPTABLES_RESTORE:-iptables-restore}"
IPT6="${DOCKER_FW_IP6TABLES:-ip6tables}"
IPT6_RESTORE="${DOCKER_FW_IP6TABLES_RESTORE:-ip6tables-restore}"
SYSTEMCTL="${DOCKER_FW_SYSTEMCTL:-systemctl}"
SYSFS_NET="${DOCKER_FW_SYSFS_NET:-/sys/class/net}"
IFACE_RE='^[A-Za-z0-9_.-]+$'
PRE_DOCKER=""   # set to 1 by --apply --pre-docker; read by docker_cli_usable and apply_v6
# Docker CLI budget: all Docker queries in one run share 10 s (see docker_bounded).
DOCKER_BUDGET=10
DOCKER_T0=$SECONDS

# Explicit grammar: no wildcard other than the exact `br-+`, never the external interface.
TRUST_SET="lo docker0 br-+ docker_gwbridge cni0 flannel.1 wg0"
PASS_SET="cni0 flannel.1"
BASELINE_TRUST=(lo docker0 'br-+' docker_gwbridge cni0 flannel.1)
BASELINE_PASS=(cni0 flannel.1)

warn() { echo "docker-user-firewall: $*" >&2; }
die()  { warn "$*"; exit 1; }

# role: dry-run/render/install may take --role; every other mode reads only the role file.
role() {
    local r="" meta owner mode
    if [[ -n "${DOCKER_FW_ROLE:-}" && "$MODE" =~ ^(--dry-run|--render|--install)$ ]]; then
        r="$DOCKER_FW_ROLE"
    else
        [[ -f "$ROLE_FILE" && ! -L "$ROLE_FILE" ]] || { warn "role file $ROLE_FILE missing (or a symlink)"; return 1; }
        meta="$(stat -c '%u %a' "$ROLE_FILE")" || return 1
        owner="${meta% *}"; mode="${meta#* }"
        [[ "$owner" == "$ROLE_UID" ]] || { warn "role file not owned by uid $ROLE_UID"; return 1; }
        (( (8#$mode & 8#022) == 0 )) || { warn "role file is group/world writable"; return 1; }
        r="$(<"$ROLE_FILE")"
    fi
    [[ "$r" =~ ^[a-z][a-z0-9-]*$ ]] || { warn "invalid host role '$r'"; return 1; }
    echo "$r"
}

# validate_allowlist ROLE: strict parse; any doubt is an error.
validate_allowlist() {
    [[ -r "$ALLOWLIST" && -s "$ALLOWLIST" ]] || { warn "allowlist missing or empty: $ALLOWLIST"; return 1; }
    awk -v role="$1" -v trust="$TRUST_SET" -v pass="$PASS_SET" -f "$HERE/docker-user-firewall.validate.awk" "$ALLOWLIST" "$ALLOWLIST"
}

# entries ROLE KIND -> remaining fields, one entry per line
entries() {
    awk -v role="$1" -v kind="$2" -f "$HERE/docker-user-firewall.entries.awk" "$ALLOWLIST"
}

# docker_cli_usable: 0 only when the Docker CLI may be queried now. Never in --pre-docker mode:
# docker.sock is socket-activated by docker.service, which is ordered AFTER this unit, so any
# Docker CLI call before docker.service starts blocks forever (boot deadlock). Every Docker query
# in this script must pass this gate.
docker_cli_usable() { [[ -z "${PRE_DOCKER:-}" ]] && command -v docker >/dev/null; }

# docker_bounded ARGS...: the only way to run the Docker CLI. The whole run gets DOCKER_BUDGET
# seconds (wall clock, via bash SECONDS, so it also holds inside $(...)); each call is
# `timeout --kill-after=2 <remaining>`. Once the budget is spent the call returns 124 without running.
# A timed-out or failed call makes callers take their existing safe fallbacks (no custom bridge
# names, no network warning, [::] check reported as before).
docker_bounded() {
    local left=$(( DOCKER_BUDGET - (SECONDS - DOCKER_T0) ))
    (( left > 0 )) || return 124
    timeout --kill-after=2 "$left" docker "$@"
}

# Docker networks with a custom bridge name (com.docker.network.bridge.name) are trusted as
# SOURCES when they are real bridge devices; the default-deny already covers them as destinations.
docker_bridge_names() {
    docker_cli_usable || return 0
    local ids n
    ids="$(docker_bounded network ls -q --filter driver=bridge 2>/dev/null)" || return 0
    [[ -n "$ids" ]] || return 0
    # shellcheck disable=SC2086
    docker_bounded network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' $ids 2>/dev/null | while read -r n; do
        if [[ "$n" =~ $IFACE_RE && -d "$SYSFS_NET/$n/bridge" ]]; then echo "$n"; fi
    done
}

# emit_rules TRUST PASSTHROUGH ALLOW   (newline-separated; allow = "proto port")
emit_rules() {
    local v p port
    echo "*filter"
    echo ":$CHAIN - [0:0]"
    echo "-A $CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
    while read -r v; do [[ -n "$v" ]] && echo "-A $CHAIN -i $v -j RETURN"; done < <(sort -u <<<"$1" | sed '/^$/d' | awk '!s[$0]++')
    while read -r v; do [[ -n "$v" ]] && echo "-A $CHAIN -o $v -j RETURN"; done <<<"$2"
    while read -r p port; do
        [[ -n "$port" ]] || continue
        echo "-A $CHAIN -p $p -m conntrack --ctstate DNAT --ctorigdstport $port --ctdir ORIGINAL -j RETURN"
    done <<<"$3"
    echo "-A $CHAIN -j DROP"
    echo "COMMIT"
}

render_rules() {
    local r="$1"
    emit_rules "$(entries "$r" trust-iface; docker_bridge_names)" "$(entries "$r" passthrough-iface)" "$(entries "$r" allow)"
}

render_baseline() {
    emit_rules "$(printf '%s\n' "${BASELINE_TRUST[@]}"; docker_bridge_names)" "$(printf '%s\n' "${BASELINE_PASS[@]}")" ""
}

# plan_rules -> rules for this host, or non-zero (diagnostics on stderr)
plan_rules() {
    local r
    r="$(role)" || return 1
    validate_allowlist "$r" || return 1
    render_rules "$r"
}

check_load() {   # name restore rules : iptables-restore --test
    local name="$1" restore="$2" rules="$3"
    if printf '%s\n' "$rules" | "$restore" -w --test --noflush 2>/dev/null; then
        echo "# $name: rules load OK (restore --test)"
    elif [[ "${DOCKER_FW_TEST_EUID:-$EUID}" -ne 0 ]]; then
        echo "# $name: loadability NOT verified (needs root); rerun with sudo"
    else
        warn "$name: rules would NOT load"; return 1
    fi
}

dry_run() {
    local rules rc=0
    rules="$(plan_rules)" || die "dry-run: policy cannot be planned; --apply would install the built-in baseline (no public ports) and exit non-zero"
    echo "# role=$(role) allowlist=$ALLOWLIST (iptables AND ip6tables)"
    echo "# 1) iptables -N DOCKER-USER 2>/dev/null || true   (Docker normally creates it)"
    echo "# 2) iptables-restore --noflush <<'RULES'   (atomic; replaces only $CHAIN; baseline if it fails on a fresh table)"
    echo "$rules"
    echo "# 3) make '-j $CHAIN' the FIRST rule of DOCKER-USER; verify FORWARD -> DOCKER-USER and the DROP"
    echo "# 4) the same for ip6tables"
    check_load iptables "$IPT4_RESTORE" "$rules" || rc=1
    if command -v "$IPT6_RESTORE" >/dev/null; then check_load ip6tables "$IPT6_RESTORE" "$rules" || rc=1
    else echo "# ip6tables: not installed (apply asserts no container publishes on [::])"; fi
    return $rc
}

first_rule_is_jump() {   # ipt
    [[ "$("$1" -w -S DOCKER-USER 2>/dev/null | grep -m1 -- '^-A')" == "-A DOCKER-USER -j $CHAIN" ]]
}

ensure_jump() {   # ipt
    local ipt="$1"
    first_rule_is_jump "$ipt" && return 0
    while "$ipt" -w -C DOCKER-USER -j "$CHAIN" 2>/dev/null && "$ipt" -w -D DOCKER-USER -j "$CHAIN" 2>/dev/null; do :; done
    "$ipt" -w -I DOCKER-USER 1 -j "$CHAIN"
}

verify_family() {   # name ipt  (full: also the FORWARD jump)
    local name="$1" ipt="$2" rc=0
    first_rule_is_jump "$ipt" || { warn "$name: '-j $CHAIN' is not the first DOCKER-USER rule"; rc=1; }
    "$ipt" -w -S "$CHAIN" 2>/dev/null | grep -q -- '-j DROP' || { warn "$name: $CHAIN has no DROP"; rc=1; }
    if [[ -z "${PRE_DOCKER:-}" ]] && ! "$ipt" -w -C FORWARD -j DOCKER-USER 2>/dev/null; then
        warn "$name: FORWARD does not jump to DOCKER-USER -- the policy is NOT ENFORCED (docker ip6tables/backend mismatch?)"; rc=1
    fi
    return $rc
}

apply_family() {   # name ipt restore rules
    local name="$1" ipt="$2" restore="$3" rules="$4" had=0
    "$ipt" -w -S "$CHAIN" >/dev/null 2>&1 && had=1
    "$ipt" -w -N DOCKER-USER 2>/dev/null || true
    if ! printf '%s\n' "$rules" | "$restore" -w --noflush; then
        warn "$name: iptables-restore failed; previous ruleset untouched"
        if [[ $had -eq 0 ]]; then
            warn "$name: fresh table -- installing the minimal baseline instead of leaving it open"
            if render_baseline | "$restore" -w --noflush; then ensure_jump "$ipt" || warn "$name: baseline jump failed"
            else warn "$name: BASELINE LOAD FAILED -- published ports are OPEN"; fi
        fi
        return 1
    fi
    ensure_jump "$ipt" || { warn "$name: could not insert the DOCKER-USER jump"; return 1; }
    verify_family "$name" "$ipt"
}

# IPv6 uses the same rules. Without an ip6tables binary the host must not publish on ::.
apply_v6() {
    local rules="$1"
    if command -v "$IPT6" >/dev/null && command -v "$IPT6_RESTORE" >/dev/null; then
        apply_family ip6tables "$IPT6" "$IPT6_RESTORE" "$rules"; return
    fi
    # --pre-docker (boot, before dockerd): the [::] publish check needs the Docker CLI, which must not
    # be called here. Without ip6tables no IPv6 filter can ever exist, and dockerd would start unfiltered
    # on [::] later, so REFUSE: exit non-zero, and the docker.service ExecStartPre stops the daemon start.
    if [[ -n "${PRE_DOCKER:-}" ]]; then
        warn "no ip6tables/ip6tables-restore at pre-docker: REFUSING startup (IPv6 would be unfiltered)"; return 1
    fi
    if docker_cli_usable && docker_bounded ps --format '{{.Ports}}' 2>/dev/null | grep -q '\[::\]'; then
        warn "no ip6tables but Docker publishes on [::]: IPv6 bypass, failing"; return 1
    fi
    warn "no ip6tables; asserted no container publishes on [::]"
}

warn_unfilterable_networks() {
    # --pre-docker: no macvlan/ipvlan network can exist yet, and the CLI must not be called. The warning
    # is emitted by the post-start apply (ExecStartPost), which runs with the daemon up.
    docker_cli_usable || return 0
    if [[ -n "$(docker_bounded network ls -q --filter driver=macvlan 2>/dev/null; docker_bounded network ls -q --filter driver=ipvlan 2>/dev/null)" ]]; then
        warn "macvlan/ipvlan Docker networks exist: their traffic never crosses host netfilter and is NOT covered"
    fi
}

apply() {
    local rules rc=0
    if ! rules="$(plan_rules)"; then
        warn "FAIL CLOSED: installing built-in baseline (no public ports)"
        rules="$(render_baseline)"; rc=1
    fi
    apply_family iptables "$IPT4" "$IPT4_RESTORE" "$rules" || rc=1
    apply_v6 "$rules" || rc=1
    warn_unfilterable_networks
    [[ $rc -eq 0 ]] && echo "applied $CHAIN (role=$(role))"
    return $rc
}

verify_all() {
    local rc=0
    verify_family iptables "$IPT4" || rc=1
    if command -v "$IPT6" >/dev/null; then verify_family ip6tables "$IPT6" || rc=1; fi
    return $rc
}

remove_family() {   # name ipt
    local name="$1" ipt="$2"
    if ! "$ipt" -w -S >/dev/null 2>&1; then warn "$name: cannot read the ruleset (not root?); NOTHING removed"; return 1; fi
    while "$ipt" -w -C DOCKER-USER -j "$CHAIN" 2>/dev/null; do "$ipt" -w -D DOCKER-USER -j "$CHAIN" || break; done
    "$ipt" -w -F "$CHAIN" 2>/dev/null || true
    "$ipt" -w -X "$CHAIN" 2>/dev/null || true
    if "$ipt" -w -S "$CHAIN" >/dev/null 2>&1 || "$ipt" -w -C DOCKER-USER -j "$CHAIN" 2>/dev/null; then
        warn "$name: $CHAIN STILL PRESENT after remove"; return 1
    fi
    echo "$name: $CHAIN removed (or was not present)"
}

remove() {
    local rc=0
    "$SYSTEMCTL" stop docker-user-firewall-reconcile.timer 2>/dev/null || true
    remove_family iptables "$IPT4" || rc=1
    if command -v "$IPT6" >/dev/null; then remove_family ip6tables "$IPT6" || rc=1; fi
    return $rc
}

install_all() {
    [[ $EUID -eq 0 ]] || die "--install needs root"
    local r; r="$(role)" || exit 1
    validate_allowlist "$r" || exit 1
    local src="$HERE/systemd"
    install -d -m 0755 "$INSTALL_DIR" "$(dirname "$ROLE_FILE")" /etc/systemd/system/docker.service.d
    install -m 0755 "$SELF" "$INSTALL_DIR/docker-user-firewall.sh"
    install -m 0644 "$ALLOWLIST" "$INSTALL_DIR/docker-user-firewall.allowlist"
    install -m 0644 "$HERE/docker-user-firewall.validate.awk" "$HERE/docker-user-firewall.entries.awk" "$INSTALL_DIR/"
    install -m 0644 "$src/docker-user-firewall.service" "$src/docker-user-firewall-reconcile.service" \
        "$src/docker-user-firewall-reconcile.timer" /etc/systemd/system/
    install -m 0644 "$src/docker.service.d/10-pneuma-docker-fw.conf" /etc/systemd/system/docker.service.d/
    printf '%s\n' "$r" > "$ROLE_FILE"; chown root:root "$ROLE_FILE"; chmod 0644 "$ROLE_FILE"
    "$SYSTEMCTL" daemon-reload
    "$SYSTEMCTL" enable docker-user-firewall.service
    echo "installed (role=$r). Boot: unit runs Before=docker.service; docker start re-applies. The reconcile timer starts on --confirm."
}

if [[ "${1:-}" == "--role" ]]; then DOCKER_FW_ROLE="${2:?--role needs a value}"; shift 2; fi
MODE="${1:---dry-run}"
case "$MODE" in
    --dry-run) dry_run ;;
    --render)  rules="$(plan_rules)" || exit 1; echo "$rules" ;;
    --apply)
        shift
        if [[ "${1:-}" == "--pre-docker" ]]; then PRE_DOCKER=1; shift; fi
        if [[ "${1:-}" == "--rollback-timer" ]]; then
            secs="${2:?--rollback-timer needs seconds}"
            [[ "$secs" =~ ^[0-9]+$ ]] || die "seconds must be an integer"
            [[ $EUID -eq 0 || -n "${DOCKER_FW_TEST_NONROOT:-}" ]] || die "--apply needs root"
            "$SYSTEMCTL" stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
            "${DOCKER_FW_SYSTEMD_RUN:-systemd-run}" --quiet --unit="$ROLLBACK_UNIT" --on-active="${secs}s" "$SELF" --remove \
                || die "could not arm the rollback timer; refusing to apply"
            echo "rollback armed in ${secs}s; keep the policy with: sudo bash $SELF --confirm"
        fi
        apply ;;
    --verify)    verify_all ;;
    --reconcile) verify_all || { warn "verification failed; re-applying"; apply; } ;;
    --confirm)
        "$SYSTEMCTL" stop "$ROLLBACK_UNIT.timer" && echo "rollback cancelled; policy kept" || die "no rollback timer to cancel"
        "$SYSTEMCTL" start docker-user-firewall-reconcile.timer || warn "install first (--install) for the reconcile timer" ;;
    --remove)  remove ;;
    --install) install_all ;;
    *) die "unknown mode $MODE" ;;
esac
