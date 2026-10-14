#!/usr/bin/env bash
# docker-user-firewall.sh -- block PUBLIC inbound to Docker-published ports by default.
#
# Docker publishes ports via DNAT in nat/PREROUTING, so they bypass INPUT and any host
# firewall. Traffic to containers traverses FORWARD -> DOCKER-USER, the only hook Docker
# leaves to operators. This script owns one sub-chain (PNEUMA-DOCKER-FW) jumped to from
# DOCKER-USER; it never edits INPUT/FORWARD policy, k3s chains or Docker's own chains.
# Rules are built from docker-user-firewall.allowlist (one file, per-role entries).
#
# Usage: docker-user-firewall.sh [--role R] [--dry-run|--render|--apply [--rollback-timer SECONDS]|--confirm|--remove|--install]
#   --dry-run   (default) print the exact commands/rules that --apply would run
#   --render    print only the iptables-restore rule body (used by tests)
#   --apply     apply atomically + idempotently; --rollback-timer SECONDS schedules --remove
#               after SECONDS via a transient systemd timer unless --confirm is run first
#   --confirm   cancel the pending rollback timer
#   --remove    remove the jump and the chain (rollback)
#   --install   install script+allowlist+systemd unit and enable it (needs root; role via
#               DOCKER_FW_ROLE or /etc/pneuma/docker-fw-role)
# One-liners: sudo bash <path> --dry-run   then   sudo bash <path> --apply --rollback-timer 300
# Env: DOCKER_FW_ROLE, DOCKER_FW_ALLOWLIST, DOCKER_FW_EXT_IFACE (default: default-route dev)
set -euo pipefail

CHAIN="PNEUMA-DOCKER-FW"
ROLE_FILE=/etc/pneuma/docker-fw-role
INSTALL_DIR=/usr/local/lib/pneuma-docker-fw
ROLLBACK_UNIT=docker-fw-rollback
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")"
ALLOWLIST="${DOCKER_FW_ALLOWLIST:-$HERE/docker-user-firewall.allowlist}"

die() { echo "docker-user-firewall: $*" >&2; exit 1; }

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
    [[ -n "$r" ]] || die "cannot determine host role (use --role, DOCKER_FW_ROLE or $ROLE_FILE)"
    echo "$r"
}

ext_iface() {
    local i="${DOCKER_FW_EXT_IFACE:-}"
    [[ -z "$i" ]] && i="$(ip -o route show default | awk '{for(k=1;k<NF;k++) if($k=="dev"){print $(k+1); exit}}')"
    [[ -n "$i" ]] || die "cannot determine external interface"
    echo "$i"
}

# entries ROLE KIND -> prints remaining fields, one entry per line
entries() {
    awk -v role="$1" -v kind="$2" '
        { sub(/#.*/, "") } NF >= 3 && ($1 == "all" || $1 == role) && $2 == kind { $1 = $2 = ""; sub(/^ +/, ""); print }
    ' "$ALLOWLIST"
}

# render_rules ROLE EXT_IFACE -> iptables-restore body (filter table, our chain only)
render_rules() {
    local r="$1" ext="$2" v p port egress
    echo "*filter"
    echo ":$CHAIN - [0:0]"
    echo "-A $CHAIN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
    while read -r v; do [[ -n "$v" ]] && echo "-A $CHAIN -i $v -j RETURN"; done < <(entries "$r" trust-iface)
    while read -r v; do [[ -n "$v" ]] && echo "-A $CHAIN -s $v ! -i $ext -j RETURN"; done < <(entries "$r" trust-cidr)
    mapfile -t egress < <(entries "$r" docker-egress)
    while read -r p port; do
        [[ -n "$port" ]] || continue
        for v in "${egress[@]}"; do
            echo "-A $CHAIN -i $ext -o $v -p $p -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j RETURN"
        done
    done < <(entries "$r" allow)
    for v in "${egress[@]}"; do echo "-A $CHAIN -i $ext -o $v -j DROP"; done
    echo "-A $CHAIN -j RETURN"
    echo "COMMIT"
}

dry_run() {
    local r ext; r="$(role)" || exit 1; ext="$(ext_iface)" || exit 1
    echo "# role=$r external-iface=$ext allowlist=$ALLOWLIST"
    echo "# 1) iptables -N DOCKER-USER 2>/dev/null || true   (Docker normally creates it)"
    echo "# 2) iptables-restore --noflush <<'RULES'   (atomic; replaces only $CHAIN)"
    render_rules "$r" "$ext"
    echo "# 3) iptables -C DOCKER-USER -j $CHAIN || iptables -I DOCKER-USER 1 -j $CHAIN"
}

apply() {
    local r ext; r="$(role)" || exit 1; ext="$(ext_iface)" || exit 1
    iptables -w -N DOCKER-USER 2>/dev/null || true
    iptables -w -F "$CHAIN" 2>/dev/null || true
    render_rules "$r" "$ext" | iptables-restore -w --noflush
    iptables -w -C DOCKER-USER -j "$CHAIN" 2>/dev/null || iptables -w -I DOCKER-USER 1 -j "$CHAIN"
    echo "applied $CHAIN (role=$r ext=$ext)"
}

remove() {
    while iptables -w -D DOCKER-USER -j "$CHAIN" 2>/dev/null; do :; done
    iptables -w -F "$CHAIN" 2>/dev/null || true
    iptables -w -X "$CHAIN" 2>/dev/null || true
    echo "removed $CHAIN"
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
    --render)  r="$(role)" || exit 1; e="$(ext_iface)" || exit 1; render_rules "$r" "$e" ;;
    --apply)
        if [[ "${2:-}" == "--rollback-timer" ]]; then
            secs="${3:?--rollback-timer needs seconds}"
            [[ "$secs" =~ ^[0-9]+$ ]] || die "seconds must be an integer"
            [[ $EUID -eq 0 ]] || die "--apply needs root"
            role >/dev/null; ext_iface >/dev/null   # fail before arming if inputs are bad
            systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
            systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${secs}s" "$SELF" --remove
            echo "rollback armed in ${secs}s; keep the policy with: sudo bash $SELF --confirm"
        fi
        apply ;;
    --confirm) systemctl stop "$ROLLBACK_UNIT.timer" && echo "rollback cancelled; policy kept" ;;
    --remove)  remove ;;
    --install) install_all ;;
    *) die "unknown mode $mode" ;;
esac
