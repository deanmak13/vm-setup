#!/usr/bin/env bash
# tests/runner-refresh.test.sh — proves bin/runner-refresh restarts exactly the
# runner units that hold a replaced library and have no job running, and that
# runner-refresh.sh / ci-builder-bootstrap.sh install it beside the needrestart
# override it completes.
#
# The program is sourced with PROC_ROOT / CGROUP_ROOT / SYSTEMCTL pointed at
# fixtures built here: a /proc tree of maps + comm files, a cgroup tree of
# cgroup.procs files, and a systemctl stand-in that lists the fixture units and
# records every restart it is asked for.
#
# Run: bash tests/runner-refresh.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
PROGRAM="$REPO_DIR/bin/runner-refresh"
INSTALLER="$REPO_DIR/runner-refresh.sh"
BOOTSTRAP="$REPO_DIR/ci-builder-bootstrap.sh"
CONF="$REPO_DIR/needrestart-actions-runner.conf"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
# check <description> <command...> — records a FAIL when the command exits non-zero.
check() {
    local label=$1 verdict=ok
    shift
    "$@" >/dev/null 2>&1 || { verdict=FAIL; fail=1; }
    printf '%-4s %s\n' "$verdict" "$label"
}
# not <command...> — negates a sourced function (a `bash -c '! fn'` cannot see it).
not() { ! "$@"; }
# expect_out <description> <expected stdout> <command...>
expect_out() {
    local label=$1 want=$2 got verdict=ok
    shift 2
    got=$("$@" 2>/dev/null) || true
    [[ $got == "$want" ]] || { verdict=FAIL; fail=1; printf '     got: %q\n' "$got"; }
    printf '%-4s %s\n' "$verdict" "$label"
}

# ── fixtures ─────────────────────────────────────────────────────────────────
PROC_ROOT="$work/proc"
CGROUP_ROOT="$work/cgroup"
SYSTEMCTL="$work/systemctl"
LOG="$work/refresh.log"
STATE_DIR="$work/state"
export PROC_ROOT CGROUP_ROOT SYSTEMCTL LOG STATE_DIR
UNITS="$work/units"        # what the stand-in's list-units prints
RESTARTS="$work/restarts"  # every unit the stand-in was asked to restart
: > "$RESTARTS"

# The stand-in prints list-units rows in systemctl's --plain shape and logs
# restarts; RESTART_FAILS makes a restart report failure.
printf '#!/usr/bin/env bash\ncase "$1" in\n  list-units) while read -r u; do printf "%%s loaded active running GitHub Actions Runner\\n" "$u"; done < "%s" ;;\n  restart) printf "%%s\\n" "$2" >> "%s"; [[ -n "${RESTART_FAILS:-}" ]] && exit 1 ;;\nesac\nexit 0\n' "$UNITS" "$RESTARTS" > "$SYSTEMCTL"
chmod 755 "$SYSTEMCTL"

# maps_line <path> [deleted] — one /proc/<pid>/maps row, padded like the kernel's.
maps_line() {
    printf '7f%08x-7f%08x r-xp 00000000 08:01 %-10s %s%s\n' $((RANDOM)) $((RANDOM + 1)) "$((RANDOM))" "$1" "${2:+ (deleted)}"
}
# process <pid> <comm> <maps-lines...>
process() {
    local pid=$1 comm=$2
    shift 2
    python3 -c 'import os,sys; os.makedirs(sys.argv[1], exist_ok=True)' "$PROC_ROOT/$pid"
    printf '%s\n' "$comm" > "$PROC_ROOT/$pid/comm"
    printf '%s\n' "$@" > "$PROC_ROOT/$pid/maps"
}
# unit <name> <pid...> — a cgroup holding those processes, listed by the stand-in.
unit() {
    local name=$1
    shift
    python3 -c 'import os,sys; os.makedirs(sys.argv[1], exist_ok=True)' "$CGROUP_ROOT/system.slice/$name"
    printf '%s\n' "$@" > "$CGROUP_ROOT/system.slice/$name/cgroup.procs"
    printf '%s\n' "$name" >> "$UNITS"
}

libc=/usr/lib/x86_64-linux-gnu/libc.so.6
tinfo=/lib/x86_64-linux-gnu/libtinfo.so.6
fresh_bash=("$(maps_line /usr/bin/bash)" "$(maps_line "$tinfo")" "$(maps_line "$libc")")
patched_bash=("$(maps_line /usr/bin/bash)" "$(maps_line "$tinfo" deleted)" "$(maps_line "$libc")")
# what every .NET process shows, plus the other "(deleted)" pseudo-files: memfd
# objects always read (deleted) whatever they are named, shm segments read
# /SYSV…, and a replaced data file is not a library
dotnet_noise=("$(maps_line /memfd:doublemapper deleted)" "$(maps_line /memfd:in-memory-plugin.so deleted)" "$(maps_line /dev/shm/scratch-plugin.so deleted)" "$(maps_line /dev/zero deleted)" "$(maps_line /SYSV00000000 deleted)" "$(maps_line /usr/lib/locale/locale-archive deleted)")

U=actions.runner.deanmak13-pneuma-engine
# idle + stale bash (ncurses patched under it) → restart
process 101 runsvc.sh "${patched_bash[@]}"
process 102 node "$(maps_line /usr/bin/node)" "$(maps_line "$libc")"
process 103 Runner.Listener "${dotnet_noise[@]}" "$(maps_line "$libc")"
unit "$U.stale-idle.service" 101 102 103
# busy + stale listener (libc patched under it) → wait
process 201 runsvc.sh "${fresh_bash[@]}"
process 202 node "$(maps_line /usr/bin/node)"
process 203 Runner.Listener "${dotnet_noise[@]}" "$(maps_line "$libc" deleted)"
process 204 Runner.Worker "${dotnet_noise[@]}" "$(maps_line "$libc" deleted)"
process 205 bash "${fresh_bash[@]}"
unit "$U.stale-busy.service" 201 202 203 204 205
# idle + only pseudo-file "(deleted)" mappings → nothing to refresh
process 301 runsvc.sh "${fresh_bash[@]}"
process 302 Runner.Listener "${dotnet_noise[@]}" "$(maps_line "$libc")"
unit "$U.fresh-idle.service" 301 302
# idle + a process that has already exited (no /proc entry) → ignored, not an error
unit "$U.gone.service" 999
# a unit whose cgroup is not readable at all (stopped) → skipped
printf '%s\n' "$U.stopped.service" >> "$UNITS"

# ── the decision functions ───────────────────────────────────────────────────
# shellcheck source=../bin/runner-refresh
source "$PROGRAM"

expect_out "stale_mappings: a deleted .so is reported with its pid" \
    "101 $tinfo" stale_mappings 101
expect_out "stale_mappings: memfd, /dev, SysV shm and data files marked (deleted) are not libraries" \
    "" stale_mappings 302
expect_out "stale_mappings: several pids → one line per stale library, in pid order" \
    "203 $libc
204 $libc" stale_mappings 201 202 203 204 205
expect_out "stale_mappings: a pid without a /proc entry contributes nothing" "" stale_mappings 999
expect_out "unit_pids: reads the unit's cgroup.procs" "101
102
103" unit_pids "$U.stale-idle.service"
expect_out "unit_pids: a unit without a cgroup yields nothing" "" unit_pids "$U.stopped.service"
check "unit_busy: a Runner.Worker in the cgroup is a job in progress" unit_busy "$U.stale-busy.service"
check "unit_busy: listener + service processes alone are idle" not unit_busy "$U.stale-idle.service"
check "refreshed_recently: no marker → not recent" not refreshed_recently "$U.stale-idle.service"
mark_refreshed "$U.stale-idle.service"
check "refreshed_recently: a marker mark_refreshed just wrote → recent" refreshed_recently "$U.stale-idle.service"
python3 -c 'import os,sys,time; os.utime(sys.argv[1], (time.time() - 7200,) * 2)' "$STATE_DIR/$U.stale-idle.service"
check "refreshed_recently: a marker older than MIN_INTERVAL → not recent" not refreshed_recently "$U.stale-idle.service"
rm -f "$STATE_DIR/$U.stale-idle.service"
expect_out "stale_summary: distinct library names, sorted" "libc.so.6 libtinfo.so.6" \
    stale_summary "$(printf '%s\n' "101 $tinfo" "203 $libc" "204 $libc")"

# ── the run ──────────────────────────────────────────────────────────────────
: > "$LOG"
check "main: exits 0 when every restart succeeds" main
expect_out "main: restarts the stale idle unit and nothing else" "$U.stale-idle.service" cat "$RESTARTS"
check "main: logs the restart with the libraries that were replaced" \
    grep -q "REFRESH $U.stale-idle.service: idle, restarted (libtinfo.so.6)" "$LOG"
check "main: logs the busy stale unit as waiting, naming its libraries" \
    grep -q "busy $U.stale-busy.service: job in progress, replaced libraries stay mapped until idle (libc.so.6)" "$LOG"
check "main: a fresh unit and a stopped unit leave no log line" \
    bash -c '! grep -qE "fresh-idle|stopped|gone" "$1"' _ "$LOG"
check "main: records the restart in a marker for the unit" test -e "$STATE_DIR/$U.stale-idle.service"

: > "$RESTARTS"; : > "$LOG"
check "main: a unit restarted under MIN_INTERVAL ago that is stale again is held, exit 0" main
expect_out "main: the held unit is not restarted again" "" cat "$RESTARTS"
check "main: the hold is logged with the libraries still mapped" \
    grep -q "HOLD $U.stale-idle.service: restarted under 60 min ago and still maps (libtinfo.so.6)" "$LOG"
rm -f "$STATE_DIR/$U.stale-idle.service"

: > "$RESTARTS"; : > "$LOG"
check "main --dry-run: exits 0" main --dry-run
expect_out "main --dry-run: restarts nothing" "" cat "$RESTARTS"
check "main --dry-run: logs what it would restart" \
    grep -q "DRY-RUN REFRESH $U.stale-idle.service: idle, would restart (libtinfo.so.6)" "$LOG"
check "main --dry-run: writes no marker" not test -e "$STATE_DIR/$U.stale-idle.service"

: > "$RESTARTS"; : > "$LOG"
RESTART_FAILS=1 check "main: a failed restart makes the run exit non-zero" not main
check "main: the failure line names the unit and its libraries" \
    grep -q "ERROR $U.stale-idle.service: idle but restart failed (libtinfo.so.6)" "$LOG"
check "main: a failed restart leaves no marker, so the next tick retries" not test -e "$STATE_DIR/$U.stale-idle.service"

# ── the program stays a program ──────────────────────────────────────────────
check "bin/runner-refresh is executable and parses" bash -n "$PROGRAM"
check "running it as a program invokes main (dry-run against the fixtures)" \
    bash -c ': > "$1"; "$2" --dry-run && grep -q "DRY-RUN REFRESH" "$1"' _ "$LOG" "$PROGRAM"

# ── agreement with the needrestart override ──────────────────────────────────
# The conf exempts a regex; the program refreshes a glob. Both must name the
# same unit prefix or a unit could be exempted and never refreshed (or refreshed
# while needrestart also restarts it).
conf_prefix=$(sed -n 's/.*qr(^\(.*\)).*= 0;/\1/p' "$CONF" | sed 's/\\\././g')
glob_prefix=$(sed -n "s/^UNIT_GLOB='\(.*\)\*'$/\1/p" "$PROGRAM")
expect_out "needrestart override and UNIT_GLOB name the same unit prefix ($glob_prefix)" "$conf_prefix" printf '%s' "$glob_prefix"
check "the conf's own comment points at runner-refresh rather than a manual restart" grep -q 'runner-refresh' "$CONF"
check "the restart markers default to /run (tmpfs), so a reboot clears them" \
    grep -q '^STATE_DIR=\${STATE_DIR:-/run/runner-refresh}' "$PROGRAM"

# ── installation ─────────────────────────────────────────────────────────────
check "runner-refresh.sh installs bin/runner-refresh to /usr/local/bin" \
    grep -q 'install -m 755 "\$REPO_DIR/bin/runner-refresh" /usr/local/bin/runner-refresh' "$INSTALLER"
check "runner-refresh.sh writes a oneshot service that runs it" \
    bash -c 'grep -q "^ExecStart=/usr/local/bin/runner-refresh$" "$1" && grep -q "^Type=oneshot$" "$1"' _ "$INSTALLER"
check "runner-refresh.sh writes a 5-minute timer and enables it" \
    bash -c 'grep -q "^OnUnitActiveSec=5min$" "$1" && grep -q "^systemctl enable --now runner-refresh.timer$" "$1"' _ "$INSTALLER"
check "runner-refresh.sh rotates the log" grep -q '^/var/log/runner-refresh.log {' "$INSTALLER"
check "ci-builder-bootstrap.sh runs runner-refresh.sh" grep -q '^bash "\$REPO_DIR/runner-refresh.sh"$' "$BOOTSTRAP"
check "the bootstrap's needrestart section points at runner-refresh for the restart" \
    bash -c 'sed -n "/needrestart: runner services/,/50-actions-runner.conf/p" "$1" | grep -q runner-refresh' _ "$BOOTSTRAP"

exit "$fail"
