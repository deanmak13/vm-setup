#!/usr/bin/env bash
# docker-user-firewall.sh -- block PUBLIC inbound to Docker-published ports by default.
#
# Docker publishes ports via DNAT in nat/PREROUTING, so they bypass INPUT and any host
# firewall. Traffic to containers traverses FORWARD -> DOCKER-USER, the only hook Docker
# leaves to operators. This script owns one sub-chain (PNEUMA-DOCKER-FW) jumped to from
# DOCKER-USER, for IPv4 AND IPv6. It never edits INPUT/FORWARD policy, k3s chains or
# Docker's own chains. Rules come from docker-user-firewall.allowlist (one file, per-role).
#
# Policy: a packet forwarded to a docker bridge is accepted only if it is ESTABLISHED/RELATED,
# arrives on a trusted interface (lo, docker bridges, CNI, wg0 for ci-builder), or targets an
# allowlisted published HOST port (conntrack original dst port). Everything else is DROPPED.
# The policy never names the external interface, so every public interface (multiple routes,
# no default route) is covered: anything not explicitly trusted is dropped.
#
# FAIL CLOSED: if the allowlist is missing/invalid or the host role is unknown, --apply installs
# a built-in baseline (trusted interfaces only, no public ports) and exits non-zero. Rules are
# loaded atomically with iptables-restore; if the load fails nothing changes (previous ruleset
# kept), the exit is non-zero and any armed rollback timer stays armed.
#
# Usage: docker-user-firewall.sh [--role R] [--dry-run|--render|--apply [--rollback-timer SECONDS]|--confirm|--remove|--install]
#   --dry-run   (default) print the exact commands/rules that --apply would run
#   --render    print only the iptables-restore rule body
#   --apply     apply v4+v6; --rollback-timer SECONDS schedules --remove after SECONDS (systemd timer)
#   --confirm   cancel the pending rollback timer
#   --remove    remove the jump and the chain (rollback)
#   --install   install script+allowlist+systemd unit and enable it (root)
# One-liners: sudo bash <path> --dry-run   then   sudo bash <path> --apply --rollback-timer 300
# Env: DOCKER_FW_ROLE, DOCKER_FW_ALLOWLIST (tests may also override the iptables binaries)
set -uo pipefail

CHAIN="PNEUMA-DOCKER-FW"
ROLE_FILE=/etc/pneuma/docker-fw-role
INSTALL_DIR=/usr/local/lib/pneuma-docker-fw
ROLLBACK_UNIT=docker-fw-rollback
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
ALLOWLIST="${DOCKER_FW_ALLOWLIST:-$HERE/docker-user-firewall.allowlist}"
IPT4="${DOCKER_FW_IPTABLES:-iptables}"
IPT4_RESTORE="${DOCKER_FW_IPTABLES_RESTORE:-iptables-restore}"
IPT6="${DOCKER_FW_IP6TABLES:-ip6tables}"
IPT6_RESTORE="${DOCKER_FW_IP6TABLES_RESTORE:-ip6tables-restore}"
IFACE_RE='^[A-Za-z0-9_.+-]+$'

# Built-in fail-closed baseline: used when the allowlist cannot be trusted.
BASELINE_TRUST=(lo docker0 'br-+' cni0 flannel.1)
BASELINE_EGRESS=(docker0 'br-+')

warn() { echo "docker-user-firewall: $*" >&2; }
die()  { warn "$*"; exit 1; }

# Role precedence: --role/DOCKER_FW_ROLE, $ROLE_FILE, then `all detect` entries in the allowlist
# (a role matches when its marker container exists). No match is an error, never a default.
role() {
    local r="${DOCKER_FW_ROLE:-}" cand kind name
    [[ -z "$r" && -r "$ROLE_FILE" ]] && r="$(<"$ROLE_FILE")"
    if [[ -z "$r" ]] && command -v docker >/dev/null; then
        while read -r cand kind name; do
            [[ "$kind" == container ]] || continue
            if docker ps -a --format '{{.Names}}' | grep -qx -- "$name"; then r="$cand"; break; fi
        done < <(awk '{sub(/#.*/,"")} $1=="all" && $2=="detect" {print $3, $4, $5}' "$ALLOWLIST")
    fi
    [[ -n "$r" ]] || { warn "cannot determine host role (use --role, DOCKER_FW_ROLE or $ROLE_FILE)"; return 1; }
    echo "$r"
}

# validate_allowlist ROLE: strict parse; any doubt is an error.
validate_allowlist() {
    local r="$1"
    [[ -r "$ALLOWLIST" && -s "$ALLOWLIST" ]] || { warn "allowlist missing or empty: $ALLOWLIST"; return 1; }
    awk -v role="$r" -v ire="$IFACE_RE" '
        { sub(/#.*/, "") } NF == 0 { next }
        { n++ }
        $2 == "trust-iface" || $2 == "docker-egress" { if (NF != 3 || $3 !~ ire) bad($0); if ($2 == "docker-egress" && ($1 == "all" || $1 == role)) egress++; next }
        $2 == "allow" { if (NF != 4 || ($3 != "tcp" && $3 != "udp") || $4 !~ /^[0-9]+$/ || $4 < 1 || $4 > 65535) bad($0); next }
        $2 == "detect" { if (NF != 5 || $1 != "all" || $4 != "container") bad($0); next }
        { bad($0) }
        function bad(l) { print "invalid allowlist line: " l > "/dev/stderr"; err = 1 }
        END {
            if (err) exit 1
            if (!egress) { print "allowlist has no docker-egress entry for this role" > "/dev/stderr"; exit 1 }
        }' "$ALLOWLIST" || return 1
    awk -v role="$r" '{sub(/#.*/,"")} $1 == role {f=1} END {exit !f}' "$ALLOWLIST" \
        || { warn "role '$r' has no entries in the allowlist (unknown role)"; return 1; }
}

# entries ROLE KIND -> remaining fields, one entry per line
entries() {
    awk -v role="$1" -v kind="$2" '
        { sub(/#.*/, "") } NF >= 3 && ($1 == "all" || $1 == role) && $2 == kind { $1 = $2 = ""; sub(/^ +/, ""); print }
    ' "$ALLOWLIST"
}

# emit_rules TRUST_LIST EGRESS_LIST ALLOW_LIST   (newline-separated; allow = "proto port")
emit_rules() {
    local v p port
    echo "*filter"
    echo ":$CHAIN - [0:0]"
    echo "-A $CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
    while read -r v; do [[ -n "$v" ]] && echo "-A $CHAIN -i $v -j RETURN"; done <<<"$1"
    while read -r p port; do
        [[ -n "$port" ]] || continue
        while read -r v; do
            [[ -n "$v" ]] && echo "-A $CHAIN -o $v -p $p -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j RETURN"
        done <<<"$2"
    done <<<"$3"
    while read -r v; do [[ -n "$v" ]] && echo "-A $CHAIN -o $v -j DROP"; done <<<"$2"
    echo "-A $CHAIN -j RETURN"
    echo "COMMIT"
}

render_rules() {
    local r="$1"
    emit_rules "$(entries "$r" trust-iface)" "$(entries "$r" docker-egress)" "$(entries "$r" allow)"
}

render_baseline() {
    emit_rules "$(printf '%s\n' "${BASELINE_TRUST[@]}")" "$(printf '%s\n' "${BASELINE_EGRESS[@]}")" ""
}

# plan_rules -> rules for this host, or non-zero (diagnostics on stderr)
plan_rules() {
    local r
    r="$(role)" || return 1
    validate_allowlist "$r" || return 1
    render_rules "$r"
}

dry_run() {
    local rules
    rules="$(plan_rules)" || die "dry-run: policy cannot be planned; --apply would install the built-in baseline (no public ports)"
    echo "# role=$(role) allowlist=$ALLOWLIST (applied to iptables AND ip6tables)"
    echo "# 1) iptables -N DOCKER-USER 2>/dev/null || true   (Docker normally creates it)"
    echo "# 2) iptables-restore --noflush <<'RULES'   (atomic; replaces only $CHAIN)"
    echo "$rules"
    echo "# 3) iptables -C DOCKER-USER -j $CHAIN || iptables -I DOCKER-USER 1 -j $CHAIN"
    echo "# 4) the same three steps with ip6tables / ip6tables-restore"
}

apply_family() {   # name ipt restore rules
    local name="$1" ipt="$2" restore="$3" rules="$4"
    "$ipt" -w -N DOCKER-USER 2>/dev/null || true
    if ! printf '%s\n' "$rules" | "$restore" -w --noflush; then
        warn "$name: iptables-restore failed; nothing was changed for $name"; return 1
    fi
    "$ipt" -w -C DOCKER-USER -j "$CHAIN" 2>/dev/null || "$ipt" -w -I DOCKER-USER 1 -j "$CHAIN" \
        || { warn "$name: could not insert the DOCKER-USER jump"; return 1; }
}

# IPv6 is covered by the same rules. Without an ip6tables binary the host must not publish on ::.
apply_v6() {
    local rules="$1"
    if command -v "$IPT6" >/dev/null && command -v "$IPT6_RESTORE" >/dev/null; then
        apply_family ip6tables "$IPT6" "$IPT6_RESTORE" "$rules"; return
    fi
    if command -v docker >/dev/null && docker ps --format '{{.Ports}}' | grep -q '\[::\]'; then
        warn "no ip6tables but Docker publishes on [::]: IPv6 bypass, failing"; return 1
    fi
    warn "no ip6tables; asserted no container publishes on [::]"
}

apply() {
    local rules rc=0
    if ! rules="$(plan_rules)"; then
        warn "FAIL CLOSED: installing built-in baseline (no public ports)"
        rules="$(render_baseline)"; rc=1
    fi
    apply_family iptables "$IPT4" "$IPT4_RESTORE" "$rules" || rc=1
    apply_v6 "$rules" || rc=1
    [[ $rc -eq 0 ]] && echo "applied $CHAIN (role=$(role))"
    return $rc
}

remove() {
    local ipt rc=0
    for ipt in "$IPT4" "$IPT6"; do
        command -v "$ipt" >/dev/null || continue
        while "$ipt" -w -D DOCKER-USER -j "$CHAIN" 2>/dev/null; do :; done
        "$ipt" -w -F "$CHAIN" 2>/dev/null || true
        "$ipt" -w -X "$CHAIN" 2>/dev/null || true
    done
    echo "removed $CHAIN"
    return $rc
}

install_all() {
    [[ $EUID -eq 0 ]] || die "--install needs root"
    local r; r="$(role)" || exit 1
    mkdir -p "$INSTALL_DIR" /etc/pneuma
    install -m 0755 "$SELF" "$INSTALL_DIR/docker-user-firewall.sh"
    install -m 0644 "$ALLOWLIST" "$INSTALL_DIR/docker-user-firewall.allowlist"
    install -m 0644 "$HERE/systemd/docker-user-firewall.service" /etc/systemd/system/docker-user-firewall.service
    echo "$r" > "$ROLE_FILE"
    systemctl daemon-reload
    systemctl enable docker-user-firewall.service
    echo "installed (role=$r); start with: systemctl start docker-user-firewall.service"
}

if [[ "${1:-}" == "--role" ]]; then DOCKER_FW_ROLE="${2:?--role needs a value}"; shift 2; fi
mode="${1:---dry-run}"
case "$mode" in
    --dry-run) dry_run ;;
    --render)  rules="$(plan_rules)" || exit 1; echo "$rules" ;;
    --apply)
        if [[ "${2:-}" == "--rollback-timer" ]]; then
            secs="${3:?--rollback-timer needs seconds}"
            [[ "$secs" =~ ^[0-9]+$ ]] || die "seconds must be an integer"
            [[ $EUID -eq 0 || -n "${DOCKER_FW_TEST_NONROOT:-}" ]] || die "--apply needs root"
            "${DOCKER_FW_SYSTEMCTL:-systemctl}" stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
            "${DOCKER_FW_SYSTEMD_RUN:-systemd-run}" --quiet --unit="$ROLLBACK_UNIT" --on-active="${secs}s" "$SELF" --remove \
                || die "could not arm the rollback timer; refusing to apply"
            echo "rollback armed in ${secs}s; keep the policy with: sudo bash $SELF --confirm"
        fi
        apply ;;
    --confirm) systemctl stop "$ROLLBACK_UNIT.timer" && echo "rollback cancelled; policy kept" ;;
    --remove)  remove ;;
    --install) install_all ;;
    *) die "unknown mode $mode" ;;
esac
