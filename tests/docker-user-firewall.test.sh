#!/usr/bin/env bash
# Tests for docker-user-firewall.sh: rule generation and every fail-closed path.
# No root or real iptables needed: iptables/ip6tables/docker are stubbed.
# The kernel-level behaviour is covered by tests/docker-user-firewall-netns.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/docker-user-firewall.sh"
ALLOW="$ROOT/docker-user-firewall.allowlist"
fails=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails+1)); }
has() { grep -qF -- "$2" <<<"$1"; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/sys/net"

# Stateful iptables stub. State per family in $W: <name>.du (DOCKER-USER rules), <name>.chain (our chain).
# Knobs: FAKE_NO_FWD=<name|all>, FAKE_NO_READ=1, FAKE_STICKY=1 (-F/-X do nothing),
#        FAKE_RESTORE_FAIL=<name|all>, FAKE_RESTORE_FAIL_ONCE=<name|all>, FAKE_TEST_FAIL=1.
for t in iptables ip6tables; do
cat > "$W/bin/$t" <<EOF
#!/bin/bash
n=$t; d="\$FAKE_DIR"; echo "\$n \$*" >> "\$FAKE_LOG"; a=" \$* "
case "\$a" in
 *" -S DOCKER-USER "*) echo "-N DOCKER-USER"; cat "\$d/\$n.du" 2>/dev/null; exit 0;;
 *" -S PNEUMA-DOCKER-FW "*) [ -f "\$d/\$n.chain" ] && { cat "\$d/\$n.chain"; exit 0; }; exit 1;;
 *" -S "*) [ -n "\${FAKE_NO_READ:-}" ] && exit 1; exit 0;;
 *" -C DOCKER-USER -j PNEUMA-DOCKER-FW "*) grep -qx -- "-A DOCKER-USER -j PNEUMA-DOCKER-FW" "\$d/\$n.du" 2>/dev/null; exit \$?;;
 *" -C FORWARD -j DOCKER-USER "*) [[ "\${FAKE_NO_FWD:-}" == all || "\${FAKE_NO_FWD:-}" == "\$n" ]] && exit 1; exit 0;;
 *" -I DOCKER-USER 1 -j PNEUMA-DOCKER-FW "*) { echo "-A DOCKER-USER -j PNEUMA-DOCKER-FW"; cat "\$d/\$n.du" 2>/dev/null; } > "\$d/tmp"; mv "\$d/tmp" "\$d/\$n.du"; exit 0;;
 *" -D DOCKER-USER -j PNEUMA-DOCKER-FW "*) grep -qx -- "-A DOCKER-USER -j PNEUMA-DOCKER-FW" "\$d/\$n.du" 2>/dev/null || exit 1
     awk 'BEGIN{r=0} !r && \$0=="-A DOCKER-USER -j PNEUMA-DOCKER-FW"{r=1; next} {print}' "\$d/\$n.du" > "\$d/tmp"; mv "\$d/tmp" "\$d/\$n.du"; exit 0;;
 *" -F PNEUMA-DOCKER-FW "*|*" -X PNEUMA-DOCKER-FW "*) [ -n "\${FAKE_STICKY:-}" ] || rm -f "\$d/\$n.chain"; exit 0;;
esac
exit 0
EOF
cat > "$W/bin/$t-restore" <<EOF
#!/bin/bash
n=$t; d="\$FAKE_DIR"; echo "\$n-restore \$*" >> "\$FAKE_LOG"
if [[ " \$* " == *" --test "* ]]; then cat >/dev/null; [ -n "\${FAKE_TEST_FAIL:-}" ] && exit 1; exit 0; fi
cat > "\$d/\$n.in"
[[ "\${FAKE_RESTORE_FAIL:-}" == all || "\${FAKE_RESTORE_FAIL:-}" == "\$n" ]] && exit 1
if [[ "\${FAKE_RESTORE_FAIL_ONCE:-}" == all || "\${FAKE_RESTORE_FAIL_ONCE:-}" == "\$n" ]] && [ ! -f "\$d/\$n.once" ]; then : > "\$d/\$n.once"; exit 1; fi
cp "\$d/\$n.in" "\$d/\$n.chain"; cp "\$d/\$n.in" "\$d/\$n.rules"
exit 0
EOF
done
printf '#!/bin/bash\necho "systemd-run $*" >> "$FAKE_LOG"\n[ -n "${FAKE_SDRUN_FAIL:-}" ] && exit 1\nexit 0\n' > "$W/bin/systemd-run"
printf '#!/bin/bash\necho "systemctl $*" >> "$FAKE_LOG"\nexit 0\n' > "$W/bin/systemctl"
printf '#!/bin/bash\necho "docker $*" >> "$FAKE_LOG"\ncase "$*" in\n "network ls -q --filter driver=bridge") cat "$FAKE_DIR/dockernets" 2>/dev/null;;\n "network inspect"*) cat "$FAKE_DIR/dockerbridges" 2>/dev/null;;\n "ps --format"*) cat "$FAKE_DIR/dockerps" 2>/dev/null;;\nesac\nexit 0\n' > "$W/bin/docker"
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH"
export FAKE_DIR="$W" FAKE_LOG="$W/log" DOCKER_FW_SYSFS_NET="$W/sys/net"
export DOCKER_FW_ROLE_FILE="$W/host-role" DOCKER_FW_ROLE_UID="$(id -u)"
export DOCKER_FW_IPTABLES=iptables DOCKER_FW_IPTABLES_RESTORE=iptables-restore
export DOCKER_FW_IP6TABLES=ip6tables DOCKER_FW_IP6TABLES_RESTORE=ip6tables-restore
export DOCKER_FW_SYSTEMD_RUN="$W/bin/systemd-run" DOCKER_FW_SYSTEMCTL="$W/bin/systemctl" DOCKER_FW_TEST_NONROOT=1
setrole() { printf '%s\n' "$1" > "$W/host-role"; chmod 0644 "$W/host-role"; }
reset() { rm -f "$W"/*.du "$W"/*.chain "$W"/*.rules "$W"/*.in "$W"/*.once "$W/log" "$W/dockernets" "$W/dockerbridges" "$W/dockerps"; : > "$W/log"
          unset FAKE_NO_FWD FAKE_NO_READ FAKE_STICKY FAKE_RESTORE_FAIL FAKE_RESTORE_FAIL_ONCE FAKE_TEST_FAIL FAKE_SDRUN_FAIL; }
render() { "$SCRIPT" --role "$1" --render; }
is_baseline() { grep -q -- '-A PNEUMA-DOCKER-FW -j DROP' "$1" && ! grep -q ctorigdstport "$1" && grep -q -- '-o cni0 -j RETURN' "$1"; }

# ---- rendering
reset
for role in dev-box ci-builder; do
    out="$(render "$role")"
    for rmq in 15692 32770 32771 5672 15672; do
        has "$out" "--ctorigdstport $rmq " && bad "$role allowlists rabbitmq port $rmq" || ok "$role: rabbitmq $rmq not allowlisted"
    done
    sed 's/#.*//' "$ALLOW" | grep -Eq '(^|[[:space:]])(15692|32770|32771)([[:space:]]|$)' \
        && bad "allowlist file contains a rabbitmq port" || ok "$role: allowlist file clean of rabbitmq ports"
    [[ "$(tail -2 <<<"$out" | head -1)" == "-A PNEUMA-DOCKER-FW -j DROP" ]] && ok "$role: chain ends in an unconditional DROP" || bad "$role: no final DROP"
    has "$out" "-i eth0" && bad "$role: names an external iface" || ok "$role: no external-iface dependence"
    while read -r l; do has "$l" "--ctstate DNAT" || bad "$role: allow without DNAT: $l"; done < <(grep ctorigdstport <<<"$out")
    ok "$role: every allow requires conntrack DNAT"
    has "$out" "--ctstate RELATED,ESTABLISHED -j RETURN" && ok "$role: established allowed" || bad "$role: no established rule"
    has "$out" "-i lo -j RETURN" && has "$out" "-i cni0 -j RETURN" && has "$out" "-o cni0 -j RETURN" && has "$out" "-o flannel.1 -j RETURN" \
        && ok "$role: loopback/CNI trusted, k3s egress passes through" || bad "$role: trust rules missing"
    first_drop=$(grep -n -m1 -- '-j DROP' <<<"$out" | cut -d: -f1)
    last_allow=$(grep -n -- '--ctorigdstport' <<<"$out" | tail -1 | cut -d: -f1)
    [[ -z "$last_allow" || "$last_allow" -lt "$first_drop" ]] && ok "$role: allows precede DROP" || bad "$role: allow after DROP"
    has "$out" "-o docker0" && bad "$role: matches egress by bridge name (custom bridges would escape)" || ok "$role: default-deny, not name-matched"
done
has "$(render dev-box)" "--ctorigdstport 3000 --ctdir ORIGINAL -j RETURN" && ok "dev-box: kodus 3000 allowed" || bad "dev-box: 3000 missing"
out="$(render ci-builder)"
for p in 3000 3001 3101 3332; do has "$out" "--ctorigdstport $p --ctdir ORIGINAL -j RETURN" && ok "ci-builder: $p allowed" || bad "ci-builder: $p missing"; done
has "$out" "-i wg0 -j RETURN" && ok "ci-builder: wg0 trusted" || bad "ci-builder: wg0 missing"
has "$(render dev-box)" "wg0" && bad "dev-box leaks wg0" || ok "dev-box has no wg0"
has "$(render dev-box)" "ctorigdstport 3001" && bad "dev-box has ci-builder port" || ok "roles are isolated"
[[ "$(render dev-box)" == "$(render dev-box)" ]] && ok "render deterministic" || bad "render nondeterministic"

# custom docker bridges: trusted as sources only when they are real bridge devices
reset; printf 'abc\n' > "$W/dockernets"; printf 'mybr0\neth0\n\n' > "$W/dockerbridges"; mkdir -p "$W/sys/net/mybr0/bridge" "$W/sys/net/eth0"
out="$(render dev-box)"
has "$out" "-i mybr0 -j RETURN" && ! has "$out" "-i eth0 " && ok "custom bridge trusted; non-bridge name (eth0) refused" || bad "custom bridge handling"

# ---- role file is the only role source for apply
check_closed() {   # label ; env + conditions already set up; runs apply, expects baseline on v4+v6 and rc != 0
    local label="$1"; reset_keep=1
    rm -f "$W"/*.du "$W"/*.chain "$W"/*.rules "$W/log"; : > "$W/log"
    "$SCRIPT" --apply --pre-docker >/dev/null 2>&1; local rc=$?
    [[ $rc -ne 0 ]] && ok "$label: exits non-zero" || bad "$label: exited 0"
    is_baseline "$W/iptables.rules" && is_baseline "$W/ip6tables.rules" && ok "$label: baseline DROP installed on v4+v6" || bad "$label: no baseline"
    grep -q -- '-I DOCKER-USER 1 -j PNEUMA-DOCKER-FW' "$W/log" && ok "$label: jump inserted" || bad "$label: no jump"
}
reset; setrole dev-box
"$SCRIPT" --apply --pre-docker >/dev/null 2>&1 && ok "role file: apply ok" || bad "role file apply failed"
cmp -s "$W/iptables.rules" "$W/ip6tables.rules" && grep -q 'ctorigdstport 3000' "$W/ip6tables.rules" && ok "IPv6 gets the same policy as IPv4" || bad "IPv6 policy differs/missing"
rm -f "$W/host-role"; check_closed "missing role file"
DOCKER_FW_ROLE=dev-box check_closed "DOCKER_FW_ROLE env is ignored by apply"
setrole 'dev-box;rm'; check_closed "garbage role"
setrole not-a-role; check_closed "undeclared role"
setrole dev-box; chmod 0666 "$W/host-role"; check_closed "group/world-writable role file"
setrole dev-box; DOCKER_FW_ROLE_UID=4242 check_closed "role file with wrong owner"
rm -f "$W/host-role"; ln -s /etc/hostname "$W/host-role"; check_closed "symlinked role file"; rm -f "$W/host-role"
setrole dev-box

# ---- strict allowlist grammar: one typo must never disable the firewall
run_al() { local f="$W/al"; printf '%b' "$2" > "$f"; DOCKER_FW_ALLOWLIST="$f" check_closed "$1"; }
base='all role dev-box\nall trust-iface lo\nall passthrough-iface cni0\n'
run_al "trust-iface +" "${base}all trust-iface +\ndev-box allow tcp 3000\n"
run_al "trust-iface eth+" "${base}all trust-iface eth+\n"
run_al "trust-iface star" "${base}all trust-iface *\n"
run_al "trust-iface external name" "${base}all trust-iface eth0\n"
run_al "trust-iface br-*" "${base}all trust-iface br-*\n"
run_al "role typo on allow" "${base}dev-bxo allow tcp 3000\n"
run_al "unknown kind" "${base}dev-box frobnicate x\n"
run_al "bad port" "${base}dev-box allow tcp 99999\n"
run_al "bad proto" "${base}dev-box allow icmp 3000\n"
run_al "passthrough eth0" "${base}all passthrough-iface eth0\n"
run_al "role not declared" "all trust-iface lo\ndev-box allow tcp 3000\n"
DOCKER_FW_ALLOWLIST="$W/nonexistent" check_closed "missing allowlist"
: > "$W/empty"; DOCKER_FW_ALLOWLIST="$W/empty" check_closed "empty allowlist"
"$SCRIPT" --role dev-box --dry-run >/dev/null 2>&1 && ok "dry-run ok on the real allowlist" || bad "dry-run on real allowlist"
printf '%b' "${base}all trust-iface +\n" > "$W/al"
DOCKER_FW_ALLOWLIST="$W/al" "$SCRIPT" --role dev-box --render >/dev/null 2>&1 && bad "render accepted a wildcard trust" || ok "render rejects wildcard trust"

# ---- (c) restore failure
reset; setrole dev-box
FAKE_RESTORE_FAIL_ONCE=iptables "$SCRIPT" --apply --pre-docker >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && is_baseline "$W/iptables.rules" && grep -q 'iptables -w -I DOCKER-USER 1' "$W/log" \
    && ok "fresh table + restore failure: baseline + jump installed, non-zero" || bad "fresh-table failure left open"
reset; "$SCRIPT" --apply --pre-docker >/dev/null 2>&1; : > "$W/log"
FAKE_RESTORE_FAIL=iptables "$SCRIPT" --apply --pre-docker >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && [[ "$(grep -c '^iptables-restore' "$W/log")" -eq 1 ]] && grep -q 'ctorigdstport 3000' "$W/iptables.chain" \
    && ok "existing chain + restore failure: previous ruleset kept, non-zero" || bad "previous ruleset not kept"
! grep -q -- ' -F ' "$W/log" && ok "apply never flushes" || bad "apply flushes"
reset; FAKE_RESTORE_FAIL=iptables "$SCRIPT" --apply --pre-docker --rollback-timer 300 >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'systemd-run.*--on-active=300s' "$W/log" && ! grep -qE 'systemctl (stop|disable) docker-fw-rollback' <(sed -n '/systemd-run/,$p' "$W/log") \
    && ok "restore failure keeps the rollback timer armed" || bad "timer disarmed on failure"
reset; FAKE_SDRUN_FAIL=1 "$SCRIPT" --apply --pre-docker --rollback-timer 300 >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'restore' "$W/log" && ok "rollback arm failure: refuses to apply (guard pinned)" || bad "applied without a rollback timer"
env -u DOCKER_FW_TEST_NONROOT bash "$SCRIPT" --apply --rollback-timer 300 >/dev/null 2>&1 && bad "non-root apply succeeded" || ok "non-root apply refused"

# ---- jump first, FORWARD jump verified in both families
reset; printf -- '-A DOCKER-USER -j RETURN\n' > "$W/iptables.du"; cp "$W/iptables.du" "$W/ip6tables.du"
"$SCRIPT" --apply >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "apply exits 0" || bad "apply rc=$rc"
for f in iptables ip6tables; do
    [[ "$(sed -n 1p "$W/$f.du")" == "-A DOCKER-USER -j PNEUMA-DOCKER-FW" ]] && ok "$f: jump is FIRST (before Docker's RETURN)" || bad "$f: jump not first"
done
"$SCRIPT" --apply >/dev/null 2>&1; [[ "$(grep -c PNEUMA-DOCKER-FW "$W/iptables.du")" -eq 1 ]] && ok "re-apply keeps exactly one jump" || bad "duplicate jumps"
printf -- '-A DOCKER-USER -j RETURN\n-A DOCKER-USER -j PNEUMA-DOCKER-FW\n' > "$W/iptables.du"
"$SCRIPT" --apply >/dev/null 2>&1; [[ "$(sed -n 1p "$W/iptables.du")" == "-A DOCKER-USER -j PNEUMA-DOCKER-FW" && "$(grep -c PNEUMA "$W/iptables.du")" -eq 1 ]] \
    && ok "a jump in the wrong position is moved to first" || bad "misplaced jump kept"
for fam in iptables ip6tables; do
    reset; FAKE_NO_FWD=$fam "$SCRIPT" --apply >"$W/out" 2>"$W/err"; rc=$?
    [[ $rc -ne 0 ]] && grep -q 'FORWARD does not jump to DOCKER-USER' "$W/err" && ok "$fam: missing FORWARD->DOCKER-USER jump fails loudly" || bad "$fam: missing FORWARD jump ignored"
done
reset; FAKE_NO_FWD=all "$SCRIPT" --apply --pre-docker >/dev/null 2>&1 && ok "--pre-docker (boot) does not require the FORWARD jump yet" || bad "pre-docker too strict"
reset; "$SCRIPT" --apply >/dev/null 2>&1; : > "$W/log"
"$SCRIPT" --reconcile >/dev/null 2>&1 && ! grep -q restore "$W/log" && ok "reconcile: healthy policy is left alone" || bad "reconcile rewrote a healthy policy"
printf -- '-A DOCKER-USER -j RETURN\n' > "$W/iptables.du"; : > "$W/log"
"$SCRIPT" --reconcile >/dev/null 2>&1; grep -q '^iptables-restore' "$W/log" && [[ "$(sed -n 1p "$W/iptables.du")" == *PNEUMA* ]] \
    && ok "reconcile: a wiped DOCKER-USER (docker rewrite) is re-applied" || bad "reconcile did not repair"
"$SCRIPT" --verify >/dev/null 2>&1 && ok "verify passes on a good policy" || bad "verify failed on good policy"
rm -f "$W/ip6tables.du"; "$SCRIPT" --verify >/dev/null 2>&1 && bad "verify missed a missing v6 jump" || ok "verify catches a missing v6 jump"

# ---- (b) IPv6 without ip6tables
reset; FAKE_RESTORE_FAIL=ip6tables "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "ip6tables restore failure: non-zero" || bad "ip6 failure swallowed"
printf '0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp\n' > "$W/dockerps"
reset; printf '0.0.0.0:3000->3000/tcp, [::]:3000->3000/tcp\n' > "$W/dockerps"
DOCKER_FW_IP6TABLES=/nonexistent/ip6tables DOCKER_FW_IP6TABLES_RESTORE=/nonexistent/r6 "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "no ip6tables + [::] published: fails" || bad "v6 bypass accepted"
reset; printf '0.0.0.0:3000->3000/tcp\n' > "$W/dockerps"
DOCKER_FW_IP6TABLES=/nonexistent/ip6tables DOCKER_FW_IP6TABLES_RESTORE=/nonexistent/r6 "$SCRIPT" --apply >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "no ip6tables but IPv6 publishing off: ok" || bad "false v6 alarm"

# ---- dry-run validates loadability
reset; dry="$("$SCRIPT" --role dev-box --dry-run)"
has "$dry" "iptables-restore --noflush" && has "$dry" "rules load OK" && has "$dry" "--ctorigdstport 3000" && ok "dry-run shows rules and validates loadability" || bad "dry-run output"
grep -q -- '--test' "$W/log" && ok "dry-run ran restore --test" || bad "dry-run did not run restore --test"
[[ "$("$SCRIPT" --role dev-box)" == "$dry" ]] && ok "dry-run is the default" || bad "default mode"
o="$(DOCKER_FW_TEST_EUID=1000 FAKE_TEST_FAIL=1 "$SCRIPT" --role dev-box --dry-run 2>&1)"; has "$o" 'NOT verified' && ok "dry-run says so when it cannot verify" || bad "dry-run overclaims"
DOCKER_FW_TEST_EUID=0 FAKE_TEST_FAIL=1 "$SCRIPT" --role dev-box --dry-run >/dev/null 2>&1 && bad "root dry-run ignored an unloadable ruleset" || ok "root dry-run fails when the rules would not load"
"$SCRIPT" --role bogus --dry-run >/dev/null 2>&1 && bad "dry-run of unknown role succeeded" || ok "dry-run of unknown role fails"

# ---- --remove reports accurately
reset; "$SCRIPT" --apply >/dev/null 2>&1; rm="$("$SCRIPT" --remove 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && has "$rm" "iptables: PNEUMA-DOCKER-FW removed" && has "$rm" "ip6tables: PNEUMA-DOCKER-FW removed" \
    && [[ ! -f "$W/iptables.chain" ]] && ok "remove: success reported and real" || bad "remove: $rm"
"$SCRIPT" --apply >/dev/null 2>&1; FAKE_STICKY=1 "$SCRIPT" --remove >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "remove that could not delete exits non-zero" || bad "remove lied"
o="$(FAKE_NO_READ=1 "$SCRIPT" --remove 2>&1)"; has "$o" 'NOTHING removed' && ok "remove without access says nothing was removed" || bad "remove claims success without access"

# ---- unit files: boot before docker, re-apply after every docker start, periodic reconcile
S="$ROOT/systemd"
grep -q '^Before=docker.service' "$S/docker-user-firewall.service" && grep -q 'WantedBy=.*docker.service' "$S/docker-user-firewall.service" \
    && ok "unit runs Before=docker.service" || bad "boot ordering"
grep -q '^ExecStartPost=-.*docker-user-firewall.sh --apply' "$S/docker.service.d/10-pneuma-docker-fw.conf" && ok "docker drop-in re-applies after every start (incl. crash restarts)" || bad "no re-apply hook"
grep -q 'reconcile' "$S/docker-user-firewall-reconcile.service" && grep -q 'OnUnitActiveSec=1min' "$S/docker-user-firewall-reconcile.timer" && ok "reconcile timer present" || bad "no reconcile timer"
bash -n "$SCRIPT" && ok "script parses" || bad "syntax"

echo; [[ $fails -eq 0 ]] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
