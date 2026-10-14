#!/usr/bin/env bash
# Kernel-level test (run by hand and in review; not in tests/coverage.sh, which only runs *.test.sh) of docker-user-firewall.sh in a throwaway user+net+mount namespace:
# real netfilter/conntrack/DNAT, no host state touched. Skips (exit 0) where unshare,
# iptables or the conntrack match are unavailable (e.g. inside the kcov container).
#
# Topology (all inside the sandbox):  ext(10.9.0.2) -- eth0[host 10.9.0.1] -- docker0 172.30.0.1 -- ctr(172.30.0.2)
# Docker-style DNAT: host:3000 -> ctr:8000 (allowlisted), host:5000 -> ctr:8000 (published, NOT allowlisted).
# ctr also listens on 3000 directly: a direct hit on the container IP must NOT ride the allowlist.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Everything below runs only inside a user namespace (kcov's container cannot create one), so it is
# marked non-code for the coverage report like the host-only sections of ci-builder-bootstrap.sh.
# [host-only-begin]
if [[ "${1:-}" != "--inside" ]]; then
    command -v unshare >/dev/null && command -v iptables >/dev/null && command -v nc >/dev/null || { echo "SKIP: unshare/iptables/nc missing"; exit 0; }
    unshare -Urnm true 2>/dev/null || { echo "SKIP: unprivileged namespaces unavailable"; exit 0; }
    exec unshare -Urnm bash "$0" --inside
fi

fails=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails+1)); }
W="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT

ip link set lo up
iptables -N X 2>/dev/null && iptables -X X || { echo "SKIP: iptables unusable in sandbox"; exit 0; }
iptables -A FORWARD -m conntrack --ctstate DNAT -j ACCEPT 2>/dev/null || { echo "SKIP: conntrack match unavailable"; exit 0; }
iptables -F FORWARD

unshare -n sleep 3000 & EXT=$!
unshare -n sleep 3000 & CTR=$!
sleep 0.3
ip link add eth0 type veth peer name extp; ip link set extp netns $EXT
ip link add docker0 type bridge; ip link add cv type veth peer name ctrp; ip link set cv master docker0; ip link set ctrp netns $CTR
ip addr add 10.9.0.1/24 dev eth0; ip addr add 172.30.0.1/24 dev docker0
ip link set eth0 up; ip link set docker0 up; ip link set cv up
nsenter -t $EXT -n sh -c 'ip link set lo up; ip addr add 10.9.0.2/24 dev extp; ip link set extp up; ip route add 172.30.0.0/24 via 10.9.0.1'
nsenter -t $CTR -n sh -c 'ip link set lo up; ip addr add 172.30.0.2/24 dev ctrp; ip link set ctrp up; ip route add default via 172.30.0.1'
sysctl -qw net.ipv4.ip_forward=1
# Docker-style publishing
iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport 3000 -j DNAT --to-destination 172.30.0.2:8000
iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -p tcp --dport 5000 -j DNAT --to-destination 172.30.0.2:8000
# Docker-style FORWARD chain wiring (v4 + v6) and the DOCKER-USER hook
for t in iptables ip6tables; do "$t" -N DOCKER-USER; "$t" -I FORWARD -j DOCKER-USER; "$t" -A DOCKER-USER -j RETURN; done

for port in 8000 3000; do nsenter -t $CTR -n sh -c "while true; do echo hello | nc -l -p $port -q1 >/dev/null 2>&1 || sleep 0.2; done" & done
sleep 0.5
reach() {   # ns-pid host port -> 0 if the TCP handshake completes
    nsenter -t "$1" -n timeout 2 bash -c "exec 3<>/dev/tcp/$2/$3" 2>/dev/null
}

# baseline: nothing filtered yet, so the sandbox itself is proven sound
reach $EXT 10.9.0.1 3000 && reach $EXT 10.9.0.1 5000 && reach $EXT 172.30.0.2 3000 \
    && ok "sandbox: before the policy every path is open" || { bad "sandbox topology broken"; echo "$fails FAILED"; exit 1; }

mkdir -p "$W/etc"; echo dev-box > "$W/etc/role"; chmod 0644 "$W/etc/role"
export DOCKER_FW_ROLE_FILE="$W/etc/role" DOCKER_FW_ROLE_UID="$(id -u)" DOCKER_FW_SYSFS_NET=/sys/class/net
"$ROOT/docker-user-firewall.sh" --apply >"$W/apply.log" 2>&1 && ok "apply succeeded in the sandbox" || { bad "apply failed: $(tail -3 "$W/apply.log")"; }

reach $EXT 10.9.0.1 3000 && ok "public -> allowlisted published port 3000: OPEN" || bad "allowlisted port blocked"
reach $EXT 10.9.0.1 5000 && bad "published but not allowlisted port 5000 is OPEN" || ok "public -> published port 5000 (not allowlisted): BLOCKED"
reach $EXT 172.30.0.2 3000 && bad "direct hit on container IP:3000 is OPEN (DNAT-less bypass)" || ok "public -> container IP:3000 directly: BLOCKED"
reach $EXT 172.30.0.2 8000 && bad "direct hit on container IP:8000 is OPEN" || ok "public -> container IP:8000 directly: BLOCKED"
nsenter -t $CTR -n timeout 2 bash -c 'exec 3<>/dev/tcp/10.9.0.2/22' 2>/dev/null; rc=$?
# container -> outside: no listener on ext, so refusal (rc!=0) is fine; what matters is the SYN is not silently dropped
nsenter -t $CTR -n timeout 3 bash -c 'echo > /dev/tcp/10.9.0.2/22' 2>&1 | grep -qi 'timed out' && bad "container egress dropped" || ok "container -> outside is not filtered"

# a one-token typo must not open the firewall: baseline is installed, rc != 0
printf 'all role dev-box\nall trust-iface +\ndev-box allow tcp 3000\n' > "$W/bad.al"
DOCKER_FW_ALLOWLIST="$W/bad.al" "$ROOT/docker-user-firewall.sh" --apply >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "wildcard trust: apply fails" || bad "wildcard trust accepted"
reach $EXT 10.9.0.1 3000 && bad "baseline left 3000 open" || ok "baseline (fail closed) blocks even the allowlisted port"
reach $EXT 172.30.0.2 3000 && bad "baseline left container IP open" || ok "baseline blocks direct container access"

# recovery and rollback
"$ROOT/docker-user-firewall.sh" --apply >/dev/null 2>&1 && reach $EXT 10.9.0.1 3000 && ok "re-apply with the good allowlist reopens 3000" || bad "recovery failed"
"$ROOT/docker-user-firewall.sh" --remove >/dev/null 2>&1; reach $EXT 172.30.0.2 3000 && ok "--remove (rollback) restores the old open state" || bad "remove did not roll back"
! iptables -S DOCKER-USER | grep -q PNEUMA && ok "remove left no jump behind" || bad "jump left behind"

echo; [[ $fails -eq 0 ]] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
# [host-only-end]
