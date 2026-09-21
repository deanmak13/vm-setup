#!/usr/bin/env bash
# tests/derive-ipv4-netplan.test.sh — derive-ipv4-netplan.sh emits an IPv4-only
# netplan derived from the live interface, and REFUSES rather than emitting a
# partial file when it cannot derive one.
#
# The bug this guards: the node's IPv6 egress to ghcr.io is dead, so any IPv6
# address on the primary interface makes containerd prefer a path that cannot
# complete a pull. Three sysctl-based attempts lost the race against networkd.
# These assertions fail if the emitted netplan ever re-admits IPv6, or if the
# DNS line regresses to the systemd-resolved stub (which would point resolution
# at itself).
#
# Run: bash tests/derive-ipv4-netplan.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
SCRIPT_UNDER_TEST="$REPO_DIR/derive-ipv4-netplan.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() {
    local label=$1 verdict=ok
    shift
    "$@" >/dev/null 2>&1 || { verdict=FAIL; fail=1; }
    printf '%-4s %s\n' "$verdict" "$label"
}

# A fake `ip` + `resolvectl` on PATH so the derivation is exercised against
# known values instead of whatever this machine happens to have.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ip" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" == *"route show default"* ]]; then
    echo "default via 10.20.30.1 dev ens5 proto static"
elif [[ "$*" == *"addr show dev ens5"* ]]; then
    echo "2: ens5    inet 10.20.30.40/24 brd 10.20.30.255 scope global ens5"
fi
FAKE
cat > "$WORK/bin/resolvectl" <<'FAKE'
#!/usr/bin/env bash
echo "Link 2 (ens5): 9.9.9.9 127.0.0.53"
FAKE
chmod +x "$WORK/bin/ip" "$WORK/bin/resolvectl"

printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2a02:c207::1:53\n' > "$WORK/resolv.conf"
OUT="$WORK/out.yaml"
PATH="$WORK/bin:$PATH" NETPLAN_RESOLV_CONF="$WORK/resolv.conf" "$SCRIPT_UNDER_TEST" > "$OUT"

grep -q 'ens5:' "$OUT"; check "interface derived from the default route" test $? -eq 0
grep -q 'addresses: \["10.20.30.40/24"\]' "$OUT"; check "address derived from the live interface" test $? -eq 0
grep -q 'via: 10.20.30.1' "$OUT"; check "default gateway derived from the live route" test $? -eq 0
grep -q 'addresses: \[1.1.1.1,8.8.8.8\]' "$OUT"; check "upstream IPv4 resolvers used, in order" test $? -eq 0

# The whole point: no IPv6 may survive into the emitted config.
! grep -qi '2a02:' "$OUT"; check "IPv6 resolver dropped (no IPv6 route to reach it)" test $? -eq 0
! grep -q '127\.0\.0\.53' "$OUT"; check "systemd-resolved stub never written as a resolver" test $? -eq 0
grep -q 'dhcp6: false' "$OUT"; check "dhcp6 disabled" test $? -eq 0
grep -q 'accept-ra: false' "$OUT"; check "router advertisements refused" test $? -eq 0
grep -q 'link-local: \[ipv4\]' "$OUT"; check "link-local restricted to ipv4" test $? -eq 0

# Falls back to resolvectl when the resolved resolv.conf is absent, and still
# refuses the loopback stub it reports.
OUT2="$WORK/out2.yaml"
PATH="$WORK/bin:$PATH" NETPLAN_RESOLV_CONF="$WORK/absent.conf" "$SCRIPT_UNDER_TEST" > "$OUT2"
grep -q 'addresses: \[9.9.9.9\]' "$OUT2"; check "falls back to resolvectl for upstream resolvers" test $? -eq 0
! grep -q '127\.0\.0\.53' "$OUT2"; check "stub filtered out of the resolvectl fallback too" test $? -eq 0

# REFUSES rather than emitting a partial file: a netplan missing an address or
# gateway could strand the host, so exit 2 and let the caller keep the old file.
cat > "$WORK/bin/ip" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$WORK/bin/ip"
rc=0
PATH="$WORK/bin:$PATH" NETPLAN_RESOLV_CONF="$WORK/resolv.conf" "$SCRIPT_UNDER_TEST" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]]; check "refuses with exit 2 when the IPv4 config cannot be derived" test $? -eq 0

# setup.sh must consume the helper rather than re-implementing the derivation,
# and must generate (validate) rather than apply to a live host.
grep -q 'derive-ipv4-netplan.sh' "$REPO_DIR/setup.sh"; check "setup.sh calls the derivation helper" test $? -eq 0
grep -q 'netplan generate' "$REPO_DIR/setup.sh"; check "setup.sh validates with netplan generate" test $? -eq 0
! grep -q 'netplan apply' "$REPO_DIR/setup.sh"; check "setup.sh never applies netplan unattended" test $? -eq 0
grep -q 'network: {config: disabled}' "$REPO_DIR/setup.sh"; check "cloud-init network regeneration disabled" test $? -eq 0

[[ "$fail" -eq 0 ]] || { echo "FAILURES"; exit 1; }
echo "all checks passed"
