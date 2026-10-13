#!/usr/bin/env bash
# gate-service-kill.check.sh — the acceptance property of the gate's SERVICE unit, on a real
# systemd. Not part of tests/coverage.sh (it needs systemd, not a kcov container); run it on
# a host with systemd (the dev box, ci-builder):  bash tests/gate-service-kill.check.sh
#
#   (1) a `setsid nohup` child that outlives the gate command is killed when the unit ends;
#   (2) the same when the main process is killed with -9 (no cleanup code runs at all);
#   (3) the main process's own exit status reaches the caller (--wait).
#
# Uses the user manager (systemd-run --user) so it runs without root. The gate runs its
# service with --uid and KillMode=control-group; this check uses the same KillMode.
set -uo pipefail
fail=0
check() { if "$@"; then echo "ok   $DESC"; else echo "FAIL $DESC"; fail=1; fi; }
if ! systemd-run --user --wait --collect --quiet -- true >/dev/null 2>&1; then
  echo "FAIL no systemd user manager here: this check cannot prove the property"; exit 1
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# (1) an outliving child, the main process exits 0
unit="pneuma-gate-killcheck-1-$$"
DESC="(1) a setsid nohup child outliving a clean main exit is killed with the unit"
systemd-run --user --unit="$unit" --wait --collect --quiet \
  --property=KillMode=control-group --property=RuntimeMaxSec=60 -- \
  bash -c 'setsid nohup sleep 300 >/dev/null 2>&1 </dev/null & echo $! > "$1"; exit 0' _ "$tmp/child1.pid"
rc1=$?
sleep 1
child1="$(cat "$tmp/child1.pid" 2>/dev/null)"
DESC="(1) the child is gone after the unit ends (main exit 0, rc=$rc1)"
check bash -c '[ -n "$1" ] && ! kill -0 "$1" 2>/dev/null' _ "$child1"

# (2) an outliving child, the main process killed with -9
unit="pneuma-gate-killcheck-2-$$"
systemd-run --user --unit="$unit" --wait --collect --quiet \
  --property=KillMode=control-group --property=RuntimeMaxSec=60 -- \
  bash -c 'setsid nohup sleep 300 >/dev/null 2>&1 </dev/null & echo $! > "$1"; kill -9 $$' _ "$tmp/child2.pid" >/dev/null 2>&1
sleep 1
child2="$(cat "$tmp/child2.pid" 2>/dev/null)"
DESC="(2) main killed with -9: the child (and so any postmaster) is gone"
check bash -c '[ -n "$1" ] && ! kill -0 "$1" 2>/dev/null' _ "$child2"

# (3) the main process's exit status reaches the caller
DESC="(3) a failing main exit status reaches the caller through --wait"
systemd-run --user --unit="pneuma-gate-killcheck-3-$$" --wait --collect --quiet -- bash -c 'exit 7' >/dev/null 2>&1
rc3=$?
check bash -c '[ "$1" != 0 ]' _ "$rc3"
exit "$fail"
