#!/usr/bin/env bash
# tests/dev-box-disk-hygiene.sh - behaviour tests for dev-box-disk-hygiene.sh.
#
# docker, df, systemctl and logger are PATH-shimmed by one recorder script that
# logs every call to $FAKE_LOG and prints canned output. DBDH_ROOT sandboxes the
# marker and the install targets, so nothing outside a temp dir is touched.
# Assertions are branch-free: a failed check sets fail=1 and the run exits 1.

set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO/dev-box-disk-hygiene.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

fail=0
FAKE_LOG="$T/calls.log"
FAKE_DF_V="$T/df-v.txt"
OUT="$T/out.txt"
MARKER="$T/root/run/dev-box-disk-low"
export FAKE_LOG FAKE_DF_V
export PATH="$T/bin:$PATH"
export DBDH_ROOT="$T/root"

mkdir -p "$T/bin" "$T/root/run"

# Shared fake: dispatches on the name it was invoked as (docker, df, ...).
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'name=${0##*/}' \
  'printf "%s %s\n" "$name" "$*" >> "$FAKE_LOG"' \
  'case "$name" in' \
  '  docker)' \
  '    case "$1" in' \
  '      info) [[ -z "${FAKE_DOCKER_DOWN:-}" ]]; exit ;;' \
  '      system) cat "$FAKE_DF_V"; exit 0 ;;' \
  '      ps) echo abc123; exit 0 ;;' \
  '      inspect) echo "abc123 2000-01-01T00:00:00Z"; exit 0 ;;' \
  '      images) printf "%s\n" i1 i2 i3; exit 0 ;;' \
  '      container|volume|image)' \
  '        [[ -z "${FAKE_PRUNE_FAIL:-}" ]] || { echo "Error: boom" >&2; exit 1; }' \
  '        echo "Total reclaimed space: 1.5GB"; exit 0 ;;' \
  '    esac ;;' \
  '  df)' \
  '    [[ -z "${FAKE_DF_BAD:-}" ]] || exit 0' \
  '    printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n"' \
  '    printf "/dev/sda1 100 %s %s 50%% /\n" $((100 - FAKE_FREE)) "$FAKE_FREE"; exit 0 ;;' \
  'esac' \
  'exit 0' > "$T/bin/fake-cmd"
chmod +x "$T/bin/fake-cmd"
for n in docker df systemctl logger; do ln -s "$T/bin/fake-cmd" "$T/bin/$n"; done

# Canned `docker system df -v`: two unused volumes (LINKS 0), one in use.
printf '%s\n' \
  'VOLUME NAME LINKS SIZE' \
  'vol1 0 2GB' \
  'vol2 1 1MB' \
  'vol3 0 500kB' \
  '' > "$FAKE_DF_V"

reset_fakes() {
  unset FAKE_DOCKER_DOWN FAKE_PRUNE_FAIL FAKE_DF_BAD
  : > "$FAKE_LOG"
}

# call <args...>: run the real script; stdout+stderr to $OUT, exit code to $rc.
call() {
  "$SCRIPT" "$@" > "$OUT" 2>&1
  rc=$?
}

# expect <what> <grep-E pattern> <want count>: count matching FAKE_LOG lines.
expect() {
  local what=$1 pat=$2 want=$3 got
  got=$(grep -cE -- "$pat" "$FAKE_LOG")
  [[ "$got" -eq "$want" ]] || { echo "FAIL: $what (got $got, want $want)" >&2; fail=1; }
}

# expect_out <what> <grep-E pattern> <want count>: count matching output lines.
expect_out() {
  local what=$1 pat=$2 want=$3 got
  got=$(grep -cE -- "$pat" "$OUT")
  [[ "$got" -eq "$want" ]] || { echo "FAIL: $what (got $got, want $want)" >&2; fail=1; }
}

# --- routine pass at healthy free space -----------------------------------
reset_fakes
export FAKE_FREE=50
call --run
expect "routine prunes exactly three" ' (container|volume|image) prune ' 3
expect "container prune uses until=6h" '^docker container prune -f --filter until=6h$' 1
expect "volume prune is unused-only" '^docker volume prune -f$' 1
expect "image prune is dangling-only" '^docker image prune -f$' 1
expect "no prune ever uses -a or --all" 'prune.* (-a|--all)' 0
expect "healthy disk raises no warning" 'daemon.warning' 0
[[ ! -e "$MARKER" ]] || { echo "FAIL: marker written at 50% free" >&2; fail=1; }
expect "reclaim totals are journaled" 'Total reclaimed space' 3
[[ "$rc" -eq 0 ]] || { echo "FAIL: --run exit $rc" >&2; fail=1; }

# --- free exactly 15%: boundary, no action ---------------------------------
reset_fakes
export FAKE_FREE=15
call --guard
expect "15% free runs no prune" ' prune ' 0
expect "15% free raises no warning" 'daemon.warning' 0
[[ ! -e "$MARKER" ]] || { echo "FAIL: marker written at 15% free" >&2; fail=1; }

# --- 10-15% free: warn and prune now, no marker ----------------------------
reset_fakes
export FAKE_FREE=12
call --guard
expect "12% free warns once" 'daemon.warning' 1
expect "12% free prunes immediately" ' (container|volume|image) prune ' 3
expect "12% free does not write the low marker" 'dev-box disk LOW' 0
[[ ! -e "$MARKER" ]] || { echo "FAIL: marker written at 12% free" >&2; fail=1; }

# --- below 10%: warn, prune, marker, one alert -----------------------------
reset_fakes
export FAKE_FREE=5
call --guard
expect "5% free warns on prune and on low space" 'daemon.warning' 2
expect "5% free prunes immediately" ' (container|volume|image) prune ' 3
expect "5% free alerts once on entry" 'dev-box disk LOW' 1
[[ -e "$MARKER" ]] || { echo "FAIL: marker not written at 5% free" >&2; fail=1; }
call --guard
expect "marker alert is not repeated while still low" 'dev-box disk LOW' 1
[[ -e "$MARKER" ]] || { echo "FAIL: marker dropped while still low" >&2; fail=1; }

# --- recovery clears the marker --------------------------------------------
export FAKE_FREE=50
call --guard
[[ ! -e "$MARKER" ]] || { echo "FAIL: marker not cleared after recovery" >&2; fail=1; }

# --- docker daemon down: routine skips, dry run reports ---------------------
reset_fakes
export FAKE_FREE=50 FAKE_DOCKER_DOWN=1
call --run
expect "docker down runs no prune" ' prune ' 0
expect "docker down is journaled as skipped" 'skip: docker daemon not reachable' 1
call --dry-run
expect_out "dry run reports docker down" 'docker daemon not reachable; nothing to report' 1

# --- a failing prune warns but the pass continues --------------------------
reset_fakes
export FAKE_FREE=50 FAKE_PRUNE_FAIL=1
call --run
expect "failed prune warns each time" 'prune failed \(rc=1\)' 3
expect "failed prunes still run the pass" ' (container|volume|image) prune ' 3

# --- unreadable free space: no prune, warn -----------------------------------
reset_fakes
export FAKE_FREE=50 FAKE_DF_BAD=1
call --guard
expect "unreadable free space warns" 'cannot read root free space' 1
expect "unreadable free space runs no prune" ' prune ' 0
call --run
expect "routine pass warns when free space is unreadable" 'cannot read root free space' 2

# --- dry run never mutates --------------------------------------------------
reset_fakes
export FAKE_FREE=50
call --dry-run
[[ "$rc" -eq 0 ]] || { echo "FAIL: --dry-run exit $rc" >&2; fail=1; }
expect "dry run calls no mutating prune" ' prune ' 0
expect "dry run queries docker system df" 'system df -v' 1
expect "dry run journals nothing" 'logger' 0
expect_out "dry run counts unused volumes" 'volumes: 2 unused would be pruned' 1
expect_out "dry run counts in-use volumes" '1 in use kept' 1
expect_out "dry run counts stale containers" 'containers: 1 exited/created older than 6h' 1
expect_out "dry run counts dangling images" 'images: 3 dangling would be pruned' 1
expect_out "dry run says nothing changed" 'dry run: nothing was changed' 1

# --- install into a temp root ----------------------------------------------
reset_fakes
export FAKE_FREE=50
call --install
[[ "$rc" -eq 0 ]] || { echo "FAIL: --install exit $rc" >&2; fail=1; }
[[ -x "$T/root/usr/local/bin/dev-box-disk-hygiene" ]] || { echo "FAIL: binary not installed" >&2; fail=1; }
cmp -s "$SCRIPT" "$T/root/usr/local/bin/dev-box-disk-hygiene" || { echo "FAIL: installed copy differs" >&2; fail=1; }
UNITS="$T/root/etc/systemd/system"
[[ -f "$UNITS/dev-box-disk-hygiene.service" ]] || { echo "FAIL: routine service missing" >&2; fail=1; }
[[ -f "$UNITS/dev-box-disk-hygiene.timer" ]] || { echo "FAIL: routine timer missing" >&2; fail=1; }
[[ -f "$UNITS/dev-box-disk-hygiene-guard.service" ]] || { echo "FAIL: guard service missing" >&2; fail=1; }
[[ -f "$UNITS/dev-box-disk-hygiene-guard.timer" ]] || { echo "FAIL: guard timer missing" >&2; fail=1; }
grep -qx "ExecStart=$T/root/usr/local/bin/dev-box-disk-hygiene --run" "$UNITS/dev-box-disk-hygiene.service" || { echo "FAIL: routine ExecStart" >&2; fail=1; }
grep -qx "ExecStart=$T/root/usr/local/bin/dev-box-disk-hygiene --guard" "$UNITS/dev-box-disk-hygiene-guard.service" || { echo "FAIL: guard ExecStart" >&2; fail=1; }
grep -qx 'OnUnitActiveSec=15min' "$UNITS/dev-box-disk-hygiene.timer" || { echo "FAIL: routine interval" >&2; fail=1; }
grep -qx 'OnUnitActiveSec=1min' "$UNITS/dev-box-disk-hygiene-guard.timer" || { echo "FAIL: guard interval" >&2; fail=1; }
expect "install reloads systemd" 'systemctl daemon-reload' 1
expect "install enables both timers" 'systemctl enable --now dev-box-disk-hygiene.timer dev-box-disk-hygiene-guard.timer' 1
expect "install runs no prune" ' prune ' 0

# --- usage -------------------------------------------------------------------
call bogus
[[ "$rc" -eq 2 ]] || { echo "FAIL: unknown argument exit $rc, want 2" >&2; fail=1; }

if [[ $fail -eq 0 ]]; then
  echo "dev-box-disk-hygiene tests: all passed"
fi
exit "$fail"
