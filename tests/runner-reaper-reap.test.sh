#!/usr/bin/env bash
# tests/runner-reaper-reap.test.sh — bin/runner-reaper's reaping decision, run
# end to end against fixture processes: ps, systemctl, logger and curl are
# stubbed on PATH, /proc is a fixture PROC_ROOT, and every path comes from a
# fixture RUNNER_REAPER_CONFIG. A repo's runner units are restarted only when
# its oldest Runner.Worker is past GRACE, the jobs API shows nothing in
# progress, AND its CPU time has been flat for two consecutive ticks; any
# other evidence (young worker, live job, CPU growth, API failure, missing
# baseline, no units) leaves it alone. --dry-run logs the reap and restarts
# nothing.
#
# Run: bash tests/runner-reaper-reap.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
REAPER_BIN="${REAPER_BIN:-$REPO_DIR/bin/runner-reaper}"

fail=0
# expect <description> <expected> <actual>
expect() {
    local verdict=ok
    [[ "$2" == "$3" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %q (expected: %q)\n' "$verdict" "$1" "$3" "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stub" "$work/rstate" "$work/lstate" "$work/proc/4242"
printf 'tok-test\n' > "$work/token"
printf '%s\n' "GRACE=600" "ALERT_REPO=vm-setup" "TOKEN_FILE_PATH=$work/token" "LOG=$work/reaper.log" \
    "STATE_DIR=$work/rstate" "LIVENESS_STATE_FILE=$work/lstate/streak.tsv" "PROC_ROOT=$work/proc" > "$work/config"

RUNNER="$work/runners/actions-runner-pneuma-engine-contabo"
mkdir -p "$RUNNER/bin.2.337.0"
printf '{"agentName":"pneuma-engine-contabo","gitHubUrl":"https://github.com/deanmak13/pneuma-engine"}\n' > "$RUNNER/.runner"
UNIT="actions.runner.deanmak13-pneuma-engine.pneuma-engine-contabo.service"

# ps prints $work/ps.out; systemctl list-units prints $work/units.out and
# restart is recorded; curl serves runs/jobs fixtures and fails on $work/fail_pattern.
printf '%s\n' '#!/usr/bin/env bash' "cat $work/ps.out 2>/dev/null; exit 0" > "$work/stub/ps"
printf '%s\n' '#!/usr/bin/env bash' "W=$work" \
    'case "$1" in list-units) cat "$W/units.out" 2>/dev/null ;; restart) shift; echo "$*" >> "$W/restarts" ;; esac' \
    'exit 0' > "$work/stub/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/stub/logger"
printf '%s\n' '#!/usr/bin/env bash' "W=$work" \
    'url=""; for a in "$@"; do case "$a" in https://*) url="$a";; esac; done' \
    'if [[ -s "$W/fail_pattern" ]] && [[ "$url" =~ $(cat "$W/fail_pattern") ]]; then exit 22; fi' \
    'case "$url" in' \
    '  */jobs) cat "$W/jobs.json" ;;' \
    '  */actions/runs*) cat "$W/runs.json" ;;' \
    '  *"/issues?"*) echo "[]" ;;' \
    '  *) echo "{}" ;;' \
    'esac' > "$work/stub/curl"
chmod +x "$work/stub/"*

worker() {  # <age-seconds> — one Runner.Worker of the fixture runner, pid 4242
    printf '4242 %s %s/bin.2.337.0/Runner.Worker spawnclient 110 113\n' "$1" "$RUNNER" > "$work/ps.out"
}
cpu() {  # <utime+stime ticks>
    printf '4242 (Runner.Worker) S 1 1 1 0 -1 0 0 0 0 0 %s 0 0 0\n' "$1" > "$work/proc/4242/stat"
}
no_jobs() { printf '{"workflow_runs":[]}\n' > "$work/runs.json"; printf '{"jobs":[]}\n' > "$work/jobs.json"; }
reset() {
    rm -f "$work/rstate/"* "$work/restarts" "$work/fail_pattern"
    : > "$work/reaper.log"
    printf '%s\n' "$UNIT loaded active running GitHub Actions Runner" > "$work/units.out"
    touch "$work/lstate/streak.tsv"
    worker 900; cpu 1000; no_jobs
}
RC=0
run() {
    RC=0
    RUNNER_REAPER_CONFIG="$work/config" PATH="$work/stub:$PATH" bash "$REAPER_BIN" "$@" >/dev/null 2>&1 || RC=$?
}
logged() { grep -c -- "$1" "$work/reaper.log" || true; }
restarts() { cat "$work/restarts" 2>/dev/null || true; }

# ── a dead worker is reaped only after two flat-CPU ticks ────────────────
reset
run; expect "tick 1 (no CPU baseline yet): not reaped" "" "$(restarts)"
expect "tick 1: logged as waiting for CPU confirmation" 1 "$(logged 'no-baseline')"
run; expect "tick 2 (quiet streak 1): not reaped" "" "$(restarts)"
run; expect "tick 3 (quiet streak 2, no job in progress): runner unit restarted" "$UNIT" "$(restarts)"
expect "tick 3: the reap is logged with its evidence" 1 "$(logged "REAP pneuma-engine: restarting: $UNIT")"
expect "tick 3: the quiet streak resets after a reap" "$(printf 'pneuma-engine\t0')" "$(cat "$work/rstate/quiet-streak.tsv")"
expect "all three ticks exit 0" 0 "$RC"

# ── an undelivered alert fails the run but never loses the reap state ───
# (the exit 1 comes after the CPU/quiet-streak state is saved: exiting
# first would reset every tick's evidence and the worker would never be
# reaped while GitHub issue writes fail)
reset; echo '/issues' > "$work/fail_pattern"
run; rc1=$RC; run; run
expect "issue search failing: each run exits 1" "1 1" "$rc1 $RC"
expect "issue search failing: the dead worker is still reaped on tick 3" "$UNIT" "$(restarts)"

# ── --dry-run never restarts ─────────────────────────────────────────────
reset; run --dry-run; run --dry-run; run --dry-run
expect "--dry-run: nothing restarted" "" "$(restarts)"
expect "--dry-run: the would-be reap is logged" 1 "$(logged 'DRY-RUN REAP pneuma-engine')"

# ── any evidence of life blocks the reap ─────────────────────────────────
reset; worker 300; run; run; run
expect "worker younger than GRACE: never reaped" "" "$(restarts)"
expect "worker younger than GRACE: jobs API never consulted" 0 "$(logged 'pneuma-engine')"

reset
printf '{"workflow_runs":[{"id":7,"status":"in_progress"},{"id":8,"status":"completed"}]}\n' > "$work/runs.json"
printf '{"jobs":[{"status":"in_progress"}]}\n' > "$work/jobs.json"
run; run; run
expect "a job in progress: never reaped" "" "$(restarts)"
expect "a job in progress: logged alive with the job evidence" 3 "$(logged 'job in-progress — not reaping (.*runs_checked=1 jobs_in_progress=1')"

reset
printf '{"workflow_runs":[{"id":7,"status":"queued"}]}\n' > "$work/runs.json"
run; run; run
expect "non-completed run whose jobs are all idle: reaped after two quiet ticks" "$UNIT" "$(restarts)"
expect "that reap's evidence counts the checked run" 1 "$(logged 'REAP pneuma-engine: .*runs_checked=1 jobs_in_progress=0')"

reset; run; cpu 1500; run; cpu 2000; run
expect "CPU time growing between ticks: never reaped" "" "$(restarts)"
expect "CPU growth is logged as the reason" 2 "$(logged 'cpu_status=active')"

reset; echo 'actions/runs' > "$work/fail_pattern"; run; run; run
expect "jobs API failing: never reaped" "" "$(restarts)"
expect "jobs API failing: skip logged" 3 "$(logged 'skip pneuma-engine: job API check failed')"

reset; rm -f "$work/proc/4242/stat"; run; run; run
expect "no /proc stat for the worker: never reaped" "" "$(restarts)"
expect "no /proc stat: logged" 3 "$(logged 'no-stat')"

reset; : > "$work/units.out"; run; run; run
expect "no matching systemd units: nothing restarted" "" "$(restarts)"
expect "no matching systemd units: logged" 1 "$(logged 'skip pneuma-engine: no matching systemd units')"

# ── only real Runner.Workers of this owner's runners count ───────────────
reset
printf '4242 900 bash -c echo %s/bin/Runner.Worker\n' "$RUNNER" > "$work/ps.out"
run; run; run
expect "a shell merely mentioning Runner.Worker is not a worker" "" "$(restarts)"

exit "$fail"
