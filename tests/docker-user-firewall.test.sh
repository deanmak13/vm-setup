#!/usr/bin/env bash
# Tests for docker-user-firewall.sh rule generation (no root, no iptables needed).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DOCKER_FW_EXT_IFACE=eth0
fails=0
render() { DOCKER_FW_ROLE="$1" "$ROOT/docker-user-firewall.sh" --render; }
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails+1)); }
has() { grep -qF -- "$2" <<<"$1"; }

for role in dev-box ci-builder; do
    out="$(render "$role")"
    for rmq in 15692 32770 32771 5672 15672; do
        has "$out" "--ctorigdstport $rmq " && bad "$role allowlists rabbitmq port $rmq" || ok "$role: rabbitmq $rmq not allowlisted"
    done
    sed 's/#.*//' "$ROOT/docker-user-firewall.allowlist" | grep -Eq '(^|[[:space:]])(15692|32770|32771)([[:space:]]|$)' \
        && bad "allowlist file contains a rabbitmq port" || ok "allowlist file clean of rabbitmq ports"
    has "$out" "-A PNEUMA-DOCKER-FW -i eth0 -o docker0 -j DROP" && has "$out" "-A PNEUMA-DOCKER-FW -i eth0 -o br-+ -j DROP" \
        && ok "$role: external->docker bridges DROP" || bad "$role: missing DROP"
    has "$out" "--ctstate RELATED,ESTABLISHED -j RETURN" && ok "$role: established allowed" || bad "$role: no established rule"
    has "$out" "-i lo -j RETURN" && has "$out" "-s 10.42.0.0/16 ! -i eth0" && has "$out" "-s 10.43.0.0/16 ! -i eth0" \
        && ok "$role: loopback + k3s CIDRs trusted" || bad "$role: trust rules missing"
    has "$out" "-o cni0" && bad "$role: touches cni0 egress" || ok "$role: k3s cni0 egress untouched"
    # every ALLOW must precede the first DROP; chain must end DROP-then-RETURN for non-external
    first_drop=$(grep -n -m1 -- '-j DROP' <<<"$out" | cut -d: -f1)
    last_allow=$(grep -n -- '--ctorigdstport' <<<"$out" | tail -1 | cut -d: -f1)
    [[ -z "$last_allow" || "$last_allow" -lt "$first_drop" ]] && ok "$role: allows precede DROP" || bad "$role: allow after DROP"
    tail -2 <<<"$out" | head -1 | grep -qx -- "-A PNEUMA-DOCKER-FW -j RETURN" && ok "$role: ends RETURN for internal" || bad "$role: bad tail"
done

out="$(render dev-box)"
has "$out" "-i eth0 -o docker0 -p tcp -m conntrack --ctorigdstport 3000 --ctdir ORIGINAL -j RETURN" && ok "dev-box: kodus 3000 allowed" || bad "dev-box: kodus 3000 missing"
out="$(render ci-builder)"
for p in 3000 3001 3101 3332; do has "$out" "--ctorigdstport $p --ctdir ORIGINAL -j RETURN" && ok "ci-builder: $p allowed" || bad "ci-builder: $p missing"; done
has "$out" "-i wg0 -j RETURN" && ok "ci-builder: wg0 trusted" || bad "ci-builder: wg0 missing"
has "$(render dev-box)" "wg0" && bad "dev-box leaks ci-builder wg0" || ok "dev-box has no wg0"
has "$(render dev-box)" "ctorigdstport 3001" && bad "dev-box has ci-builder port" || ok "roles are isolated"
# role detection and explicit errors (docker stubbed via PATH)
stub="$(mktemp -d)"; printf '#!/bin/sh\necho kodus-fwd-3000\n' > "$stub/docker"; chmod +x "$stub/docker"
[[ "$(PATH="$stub:$PATH" env -u DOCKER_FW_ROLE "$ROOT/docker-user-firewall.sh" --render | grep -c 'ctorigdstport 3332')" -gt 0 ]] \
    && ok "role detected from marker container" || bad "role detection failed"
printf '#!/bin/sh\necho nothing\n' > "$stub/docker"
PATH="$stub:$PATH" env -u DOCKER_FW_ROLE "$ROOT/docker-user-firewall.sh" --render >/dev/null 2>&1 \
    && bad "unknown host got a default role" || ok "unknown host is an error"
"$ROOT/docker-user-firewall.sh" --role ci-builder --render | grep -q 'ctorigdstport 3101' && ok "--role flag" || bad "--role flag"
bash "$ROOT/docker-user-firewall.sh" --role dev-box --apply --rollback-timer 300 >/dev/null 2>&1 \
    && bad "non-root apply succeeded" || ok "non-root apply refused"
rm -rf "$stub"
# idempotent render
[[ "$(render dev-box)" == "$(render dev-box)" ]] && ok "render deterministic" || bad "render nondeterministic"

echo; [[ $fails -eq 0 ]] && echo "ALL PASSED" || { echo "$fails FAILED"; exit 1; }
