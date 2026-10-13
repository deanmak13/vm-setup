#!/usr/bin/env bash
# gate-service-kill.check.sh — the acceptance properties of the gate SERVICE, on a real
# systemd. Not part of tests/coverage.sh (it needs systemd, not a kcov container). Run it on
# a host with systemd (the dev box, ci-builder):   bash tests/gate-service-kill.check.sh
#
#   (1) a `setsid nohup` child that outlives the gate command is killed when the unit ends;
#   (2) kill -9 of the main process leaves no child (no postmaster) and no run directory;
#   (3) the main process's exit status reaches the caller through --wait;
#   (4) a slow start keeps its run directory for as long as the unit runs (nothing deletes it);
#   (5) the unit inherits no fd the caller holds (the admission lock never reaches the gate).
#
# Uses the user manager (systemd-run --user), so no root is needed. The gate runs with
# KillMode=control-group and RuntimeDirectory=; this check uses the same properties.
set -uo pipefail
fail=0
DESC=""
check() { if "$@"; then echo "ok   $DESC"; else echo "FAIL $DESC"; fail=1; fi; }
if ! systemd-run --user --wait --collect --quiet -- true >/dev/null 2>&1; then
  echo "FAIL no systemd user manager here: this check cannot prove the properties"; exit 1
fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"   # where RuntimeDirectory= lands for a user unit

# (1) an outliving child, the main process exits 0
DESC="(1) a setsid nohup child outliving a clean main exit is killed with the unit"
systemd-run --user --unit="pneuma-gate-kc1-$$" --wait --collect --quiet \
  --property=KillMode=control-group --property=RuntimeMaxSec=60 -- \
  bash -c 'setsid nohup sleep 300 >/dev/null 2>&1 </dev/null & echo $! > "$1"; exit 0' _ "$tmp/child1.pid"
rc1=$?
sleep 1
child1="$(cat "$tmp/child1.pid" 2>/dev/null)"
DESC="(1) the child is gone after the unit ends (main exit 0, rc=$rc1)"
check bash -c '[ -n "$1" ] && ! kill -0 "$1" 2>/dev/null' _ "$child1"

# (2) kill -9 of the main process: the child (a stand-in postmaster) and the run directory go
id2="kc2-$$"
systemd-run --user --unit="pneuma-gate-$id2" --wait --collect --quiet \
  --property=KillMode=control-group --property=RuntimeMaxSec=60 \
  --property=RuntimeDirectory="pneuma-gate/$id2" --property=RuntimeDirectoryMode=0700 -- \
  bash -c 'mkdir -p "$XDG_RUNTIME_DIR/pneuma-gate/'"$id2"'/pg"; setsid nohup sleep 300 >/dev/null 2>&1 </dev/null & echo $! > "$1"; kill -9 $$' _ "$tmp/child2.pid" >/dev/null 2>&1
sleep 1
child2="$(cat "$tmp/child2.pid" 2>/dev/null)"
DESC="(2) kill -9 of the main process: the child is gone"
check bash -c '[ -n "$1" ] && ! kill -0 "$1" 2>/dev/null' _ "$child2"
DESC="(2) kill -9 of the main process: the run directory is removed with the unit"
check bash -c '[ ! -e "$1/pneuma-gate/'"$id2"'" ]' _ "$rt"

# (3) the main process's exit status reaches the caller
DESC="(3) a failing main exit status reaches the caller through --wait"
systemd-run --user --unit="pneuma-gate-kc3-$$" --wait --collect --quiet -- bash -c 'exit 7' >/dev/null 2>&1
rc3=$?
check bash -c '[ "$1" != 0 ]' _ "$rc3"

# (4) a slow start: the run directory exists for as long as the unit runs, and is gone after
id4="kc4-$$"
systemd-run --user --unit="pneuma-gate-$id4" --wait --collect --quiet \
  --property=RuntimeMaxSec=60 --property=RuntimeDirectory="pneuma-gate/$id4" \
  --property=RuntimeDirectoryMode=0700 -- \
  bash -c 'sleep 4; test -d "$XDG_RUNTIME_DIR/pneuma-gate/'"$id4"'" && echo present > "$1"' _ "$tmp/slow.out" >/dev/null 2>&1
DESC="(4) a slow start keeps its run directory while the unit runs"
check bash -c '[ "$(cat "$1" 2>/dev/null)" = present ]' _ "$tmp/slow.out"
DESC="(4) and it is removed once the unit has ended"
check bash -c '[ ! -e "$1/pneuma-gate/'"$id4"'" ]' _ "$rt"

# (5) fds: a lock the caller holds is not open inside the unit
exec 9>"$tmp/admit.lock"
DESC="(5) the unit inherits no fd of the caller (the admission lock stays with the caller)"
systemd-run --user --unit="pneuma-gate-kc5-$$" --wait --collect --quiet -- \
  bash -c 'ls -l /proc/self/fd | grep -c admit.lock > "$1"' _ "$tmp/fds.out" >/dev/null 2>&1
check bash -c '[ "$(cat "$1" 2>/dev/null)" = 0 ]' _ "$tmp/fds.out"
exec 9>&-
exit "$fail"
