#!/usr/bin/env bash
# tests/gate-durations-dirs.test.sh — host/gate-durations-dirs.sh against a temp base (no root, no host).
# Proves: one dir per listed repo (data-driven), mode 0755 and not world-writable, idempotent re-run, a new
# list line adds a dir with no code change, bad names/missing owner/empty list are refused, and the installer
# stages the script and the list on both paths.
#   bash tests/gate-durations-dirs.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$REPO/host/gate-durations-dirs.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }
me="$(id -un)"

printf '# c\npneuma-engine\n' > "$work/l1"
bash "$S" "$work/b" "$me" "$work/l1" >/dev/null; rc=$?
if [ "$rc" = 0 ] && [ -d "$work/b/durations/pneuma-engine" ]; then pass "creates durations/<repo> for the listed repo"; else bad "create (rc $rc)"; fi
if [ "$(stat -c %a "$work/b/durations/pneuma-engine")" = 755 ] && [ "$(stat -c %a "$work/b/durations")" = 755 ]; then pass "0755, not world-writable"; else bad "modes"; fi
chmod 0777 "$work/b/durations/pneuma-engine"
if bash "$S" "$work/b" "$me" "$work/l1" >/dev/null && [ "$(stat -c %a "$work/b/durations/pneuma-engine")" = 755 ]; then pass "idempotent: a re-run converges the mode"; else bad "idempotent"; fi
printf 'pneuma-engine\nsixth-repo # new\n' > "$work/l2"
if bash "$S" "$work/b" "$me" "$work/l2" >/dev/null && [ -d "$work/b/durations/sixth-repo" ]; then pass "a new list line adds a repo with no code change"; else bad "new repo"; fi
for n in '../x' 'A_B' '-x' 'a/b'; do
  printf '%s\n' "$n" > "$work/l3"
  if bash "$S" "$work/b2" "$me" "$work/l3" >/dev/null 2>&1; then bad "accepted bad name '$n'"; else pass "refuses bad repo name '$n'"; fi
done
: > "$work/l4"
if bash "$S" "$work/b2" "$me" "$work/l4" >/dev/null 2>&1; then bad "empty list accepted"; else pass "refuses an empty list"; fi
if bash "$S" "$work/b2" no-such-user-xyz "$work/l1" >/dev/null 2>&1; then bad "missing owner accepted"; else pass "refuses a missing owner"; fi
if [ ! -e "$work/b2" ]; then pass "a refused run creates nothing"; else bad "refused run created $work/b2"; fi
if grep -q 'gate-durations-dirs.sh' "$REPO/ci-builder-gate-host.sh" && [ "$(grep -c 'gate-durations-repos.txt' "$REPO/ci-builder-gate.sh")" -ge 2 ]; then
  pass "host step runs it; both staging paths ship the script and list"; else bad "wiring"; fi
if grep -q '^pneuma-engine$' "$REPO/gate-durations-repos.txt"; then pass "the shipped list starts with pneuma-engine"; else bad "shipped list"; fi
if [ "$fails" = 0 ]; then echo "gate-durations-dirs: all checks passed"; exit 0; fi
echo "gate-durations-dirs: $fails FAILED"; exit 1
