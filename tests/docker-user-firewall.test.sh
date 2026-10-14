#!/usr/bin/env bash
# Tests for docker-user-firewall.sh: rule generation and every fail-closed path.
# No root or real iptables needed: iptables/ip6tables are stubbed via the DOCKER_FW_* overrides.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/docker-user-firewall.sh"
fails=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails+1)); }
has() { grep -qF -- "$2" <<<"$1"; }
render() { DOCKER_FW_ROLE="$1" "$SCRIPT" --render; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
# Stub toolchain: every call is logged; *-restore saves stdin per family; FAKE_RESTORE_FAIL=<name> fails it.
mkdir -p "$W/bin"
for t in iptables ip6tables; do
    printf '#!/bin/bash\necho "%s $*" >> "$FAKE_LOG"\n[[ "$*" == *" -C "* || "$*" == *" -D "* ]] && exit 1\nexit 0\n' "$t" > "$W/bin/$t"
    printf '#!/bin/bash\necho "%s-restore $*" >> "$FAKE_LOG"\ncat > "$FAKE_DIR/%s.rules"\n[[ "${FAKE_RESTORE_FAIL:-}" == "%s" || "${FAKE_RESTORE_FAIL:-}" == all ]] && exit 1\nexit 0\n' "$t" "$t" "$t" > "$W/bin/$t-restore"
done
printf '#!/bin/bash\necho "systemd-run $*" >> "$FAKE_LOG"\n' > "$W/bin/systemd-run"
printf '#!/bin/bash\necho "systemctl $*" >> "$FAKE_LOG"\n' > "$W/bin/systemctl"
chmod +x "$W/bin/"*
export FAKE_DIR="$W" FAKE_LOG="$W/log"
export DOCKER_FW_IPTABLES="$W/bin/iptables" DOCKER_FW_IPTABLES_RESTORE="$W/bin/iptables-restore"
export DOCKER_FW_IP6TABLES="$W/bin/ip6tables" DOCKER_FW_IP6TABLES_RESTORE="$W/bin/ip6tables-restore"
export DOCKER_FW_SYSTEMD_RUN="$W/bin/systemd-run" DOCKER_FW_SYSTEMCTL="$W/bin/systemctl" DOCKER_FW_TEST_NONROOT=1
reset() { rm -f "$W/log" "$W/"*.rules; : > "$W/log"; }
is_baseline() {   # rules file: DROP present, no public port allowed
    grep -q -- '-o docker0 -j DROP' "$1" && grep -q -- '-o br-+ -j DROP' "$1" && ! grep -q ctorigdstport "$1"
}

# ---- rendering
for role in dev-box ci-builder; do
    out="$(render "$role")"
    for rmq in 15692 32770 32771 5672 15672; do
        has "$out" "--ctorigdstport $rmq " && bad "$role allowlists rabbitmq port $rmq" || ok "$role: rabbitmq $rmq not allowlisted"
    done
    sed 's/#.*//' "$ROOT/docker-user-firewall.allowlist" | grep -Eq '(^|[[:space:]])(15692|32770|32771)([[:space:]]|$)' \
        && bad "allowlist file contains a rabbitmq port" || ok "$role: allowlist file clean of rabbitmq ports"
    has "$out" "-A PNEUMA-DOCKER-FW -o docker0 -j DROP" && has "$out" "-A PNEUMA-DOCKER-FW -o br-+ -j DROP" \
        && ok "$role: any non-trusted traffic to docker bridges DROPPED" || bad "$role: missing DROP"
    has "$out" "-i eth0" && bad "$role: policy depends on a named external iface" || ok "$role: no external-iface dependence (covers all public ifaces)"
    has "$out" "--ctstate RELATED,ESTABLISHED -j RETURN" && ok "$role: established allowed" || bad "$role: no established rule"
    has "$out" "-i lo -j RETURN" && has "$out" "-i cni0 -j RETURN" && ok "$role: loopback + CNI trusted" || bad "$role: trust rules missing"
    has "$out" "-o cni0" && bad "$role: touches cni0 egress" || ok "$role: k3s cni0 egress untouched"
    first_drop=$(grep -n -m1 -- '-j DROP' <<<"$out" | cut -d: -f1)
    last_allow=$(grep -n -- '--ctorigdstport' <<<"$out" | tail -1 | cut -d: -f1)
    [[ -z "$last_allow" || "$last_allow" -lt "$first_drop" ]] && ok "$role: allows precede DROP" || bad "$role: allow after DROP"
    [[ "$(tail -2 <<<"$out" | head -1)" == "-A PNEUMA-DOCKER-FW -j RETURN" ]] && ok "$role: ends RETURN" || bad "$role: bad tail"
done
has "$(render dev-box)" "--ctorigdstport 3000 --ctdir ORIGINAL -j RETURN" && ok "dev-box: kodus 3000 allowed" || bad "dev-box: 3000 missing"
out="$(render ci-builder)"
for p in 3000 3001 3101 3332; do has "$out" "--ctorigdstport $p --ctdir ORIGINAL -j RETURN" && ok "ci-builder: $p allowed" || bad "ci-builder: $p missing"; done
has "$out" "-i wg0 -j RETURN" && ok "ci-builder: wg0 trusted" || bad "ci-builder: wg0 missing"
has "$(render dev-box)" "wg0" && bad "dev-box leaks wg0" || ok "dev-box has no wg0"
has "$(render dev-box)" "ctorigdstport 3001" && bad "dev-box has ci-builder port" || ok "roles are isolated"
[[ "$(render dev-box)" == "$(render dev-box)" ]] && ok "render deterministic" || bad "render nondeterministic"

# ---- role selection
mkdir -p "$W/dock"; printf '#!/bin/sh\necho kodus-fwd-3000\n' > "$W/dock/docker"; chmod +x "$W/dock/docker"
PATH="$W/dock:$PATH" env -u DOCKER_FW_ROLE "$SCRIPT" --render | grep -q 'ctorigdstport 3332' && ok "role detected from marker container" || bad "role detection"
printf '#!/bin/sh\necho nothing\n' > "$W/dock/docker"
PATH="$W/dock:$PATH" env -u DOCKER_FW_ROLE "$SCRIPT" --render >/dev/null 2>&1 && bad "unknown host rendered a policy" || ok "unknown host: render errors"
"$SCRIPT" --role ci-builder --render | grep -q 'ctorigdstport 3101' && ok "--role flag" || bad "--role flag"
dry="$("$SCRIPT" --role dev-box --dry-run)"
has "$dry" "iptables-restore --noflush" && has "$dry" "ip6tables" && has "$dry" "--ctorigdstport 3000" && ok "dry-run shows commands, rules, ip6" || bad "dry-run output"
[[ "$("$SCRIPT" --role dev-box)" == "$dry" ]] && ok "dry-run is the default" || bad "default mode"
"$SCRIPT" --role bogus --dry-run >/dev/null 2>&1 && bad "dry-run of unknown role succeeded" || ok "dry-run of unknown role fails"
env -u DOCKER_FW_TEST_NONROOT bash "$SCRIPT" --role dev-box --apply --rollback-timer 300 >/dev/null 2>&1 \
    && bad "non-root apply succeeded" || ok "non-root apply refused"

# ---- apply: happy path covers v4 AND v6 with identical rules
reset; DOCKER_FW_ROLE=dev-box "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "apply exits 0" || bad "apply rc=$rc"
cmp -s "$W/iptables.rules" "$W/ip6tables.rules" && grep -q 'ctorigdstport 3000' "$W/ip6tables.rules" && ok "IPv6 gets the same policy as IPv4" || bad "IPv6 policy differs/missing"
grep -q 'ip6tables -w -I DOCKER-USER 1 -j PNEUMA-DOCKER-FW' "$W/log" && ok "ip6tables jump inserted" || bad "no ip6 jump"
reset; DOCKER_FW_ROLE=dev-box "$SCRIPT" --apply >/dev/null 2>&1; DOCKER_FW_ROLE=dev-box "$SCRIPT" --apply >/dev/null 2>&1
! grep -q -- ' -F ' "$W/log" && ok "apply never flushes (atomic restore only)" || bad "apply flushes"

# ---- fail closed (a): bad allowlist / unknown role / empty -> baseline + nonzero, DROP never skipped
check_closed() {   # label, env... ; runs apply and checks baseline on both families
    local label="$1"; shift; reset
    env "$@" "$SCRIPT" --apply >/dev/null 2>&1; local rc=$?
    [[ $rc -ne 0 ]] && ok "$label: exits non-zero" || bad "$label: exited 0"
    is_baseline "$W/iptables.rules" && is_baseline "$W/ip6tables.rules" && ok "$label: baseline DROP installed on v4+v6" || bad "$label: no baseline"
    grep -q -- '-I DOCKER-USER 1 -j PNEUMA-DOCKER-FW' "$W/log" && ok "$label: jump inserted" || bad "$label: no jump"
}
check_closed "missing allowlist" DOCKER_FW_ROLE=dev-box DOCKER_FW_ALLOWLIST="$W/nonexistent"
: > "$W/empty"; check_closed "empty allowlist" DOCKER_FW_ROLE=dev-box DOCKER_FW_ALLOWLIST="$W/empty"
printf 'all trust-iface lo\nall docker-egress br-+\ndev-box frobnicate x\n' > "$W/junk"; check_closed "unparseable allowlist" DOCKER_FW_ROLE=dev-box DOCKER_FW_ALLOWLIST="$W/junk"
printf 'all trust-iface lo\nall docker-egress br-+\ndev-box allow tcp 99999\n' > "$W/badport"; check_closed "bad port" DOCKER_FW_ROLE=dev-box DOCKER_FW_ALLOWLIST="$W/badport"
printf 'all trust-iface lo\ndev-box allow tcp 3000\n' > "$W/noegress"; check_closed "no docker-egress (would skip DROP)" DOCKER_FW_ROLE=dev-box DOCKER_FW_ALLOWLIST="$W/noegress"
check_closed "unknown role" DOCKER_FW_ROLE=not-a-role
mkdir -p "$W/d2"; printf '#!/bin/sh\necho nothing\n' > "$W/d2/docker"; chmod +x "$W/d2/docker"
reset; PATH="$W/d2:$PATH" env -u DOCKER_FW_ROLE "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && is_baseline "$W/iptables.rules" && ok "undetectable role: baseline + non-zero" || bad "undetectable role"

# ---- fail closed (b): IPv6
reset; DOCKER_FW_ROLE=dev-box FAKE_RESTORE_FAIL=ip6tables "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "ip6tables restore failure: non-zero" || bad "ip6 failure swallowed"
printf '#!/bin/sh\necho "0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp"\n' > "$W/d2/docker"
reset; PATH="$W/d2:$PATH" DOCKER_FW_ROLE=dev-box DOCKER_FW_IP6TABLES=/nonexistent/ip6tables "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "no ip6tables + [::] published: fails" || bad "v6 bypass accepted"
printf '#!/bin/sh\necho "0.0.0.0:3000->3000/tcp"\n' > "$W/d2/docker"
reset; PATH="$W/d2:$PATH" DOCKER_FW_ROLE=dev-box DOCKER_FW_IP6TABLES=/nonexistent/ip6tables "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "no ip6tables but IPv6 publishing asserted off: ok" || bad "false v6 alarm"

# ---- fail closed (c): partial apply -> non-zero, no jump, rollback timer stays armed
reset; DOCKER_FW_ROLE=dev-box FAKE_RESTORE_FAIL=iptables "$SCRIPT" --apply --rollback-timer 300 >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "restore failure: non-zero" || bad "restore failure swallowed"
! grep -q '^iptables -w -I' "$W/log" && ok "no v4 jump after failed restore" || bad "jump inserted after failed restore"
grep -q 'systemd-run.*--on-active=300s' "$W/log" && ok "rollback timer armed" || bad "timer not armed"
! grep -qE 'systemctl (stop|disable).*timer' <(sed -n '/systemd-run/,$p' "$W/log") && ok "timer stays armed after failure" || bad "timer disarmed on failure"
! grep -q -- ' -F ' "$W/log" && ok "failed restore flushed nothing (previous rules kept)" || bad "flush on failure"

# ---- remove covers both families
reset; "$SCRIPT" --remove >/dev/null 2>&1
grep -q '^iptables -w -X' "$W/log" && grep -q '^ip6tables -w -X' "$W/log" && ok "remove cleans v4+v6" || bad "remove incomplete"

echo; [[ $fails -eq 0 ]] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
