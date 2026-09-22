#!/usr/bin/env bash
# tests/runner-reaper-crosswatch.test.sh — runner-reaper's cross-watch on
# runner-liveness-check's state file, run end to end: bin/runner-reaper itself
# (so kcov measures it), its paths pointed at a temp dir through a fixture
# RUNNER_REAPER_CONFIG and curl/ps/logger/systemctl stubbed on PATH.
# No network, no root, no host state. Covers round-3 review of vm-setup#9:
#   - both sides of the LIVENESS_STALE_SECONDS (1200s) threshold;
#   - a failed issue search never files a duplicate and fails the run;
#   - any delivery failure (search, file, comment, close) exits non-zero so
#     runner-reaper.service's OnFailure= unit fires;
#   - "still stale" comments are throttled to one per hour;
#   - --alert-repo is honoured; the OnFailure issue's close is debounced;
#   - the token never reaches curl's argv or the log.
#
# Run: bash tests/runner-reaper-crosswatch.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
REAPER_BIN="${REAPER_BIN:-$REPO_DIR/bin/runner-reaper}"
INSTALLER="$REPO_DIR/runner-reaper.sh"
FAILURE_ALERT="$REPO_DIR/bin/runner-failure-alert"

fail=0
# expect <description> <expected> <actual>
expect() {
    local verdict=ok
    [[ "$2" == "$3" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %q (expected: %q)\n' "$verdict" "$1" "$3" "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stub" "$work/rstate" "$work/lstate" "$work/tmp"
TOKEN_VALUE="tok-SECRET-$$"
printf '%s\n' "$TOKEN_VALUE" > "$work/token"

# ── fixture configs: every path redirected into $work ─────────────────────
write_config() {  # <alert-repo> <out>
    printf '%s\n' "GRACE=600" "ALERT_REPO=$1" "TOKEN_FILE_PATH=$work/token" "LOG=$work/reaper.log" \
        "STATE_DIR=$work/rstate" "LIVENESS_STATE_FILE=$work/lstate/streak.tsv" > "$2"
}
write_config vm-setup "$work/config"
write_config my-alerts "$work/config-alt"

# ── stubs ────────────────────────────────────────────────────────────────
# curl: records "METHOD URL" (and the full argv, for the token check),
# fails when "METHOD URL" matches $work/fail_pattern, serves the open-issue
# list from $work/issues.json.
printf '%s\n' '#!/usr/bin/env bash' \
    "W=$work" \
    'url=""; method=GET; prev=""' \
    'for a in "$@"; do case "$a" in https://*) url="$a";; esac; [[ "$prev" == "-X" ]] && method="$a"; prev="$a"; done' \
    'echo "$method $url" >> "$W/curl.calls"' \
    'echo "$*" >> "$W/curl.argv"' \
    'if [[ -s "$W/fail_pattern" ]] && [[ "$method $url" =~ $(cat "$W/fail_pattern") ]]; then exit 22; fi' \
    'case "$url" in' \
    '  *"/issues?"*) if [[ -f "$W/issues.json" ]]; then cat "$W/issues.json"; else echo "[]"; fi ;;' \
    '  */issues) echo "{\"number\": 99}" ;;' \
    '  *) echo "{}" ;;' \
    'esac' > "$work/stub/curl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/stub/ps"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/stub/logger"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/stub/systemctl"
chmod +x "$work/stub/"*

STALE_TITLE="[runner-liveness] the liveness checker's timer appears to have stopped"
FAILURE_TITLE="[runner-reaper] runner-reaper failed (crash or undelivered alert)"

RC=0
run() {  # [config] — one reaper run; sets RC, leaves curl.calls/reaper.log for inspection
    : > "$work/curl.calls"; : > "$work/reaper.log"
    RC=0
    RUNNER_REAPER_CONFIG="${1:-$work/config}" TMPDIR="$work/tmp" PATH="$work/stub:$PATH" bash "$REAPER_BIN" >/dev/null 2>&1 || RC=$?
}
stale() { touch -d "@$(( $(date +%s) - $1 ))" "$work/lstate/streak.tsv"; }
calls() { grep -c -- "$1" "$work/curl.calls" || true; }
open_issues() {  # <number> <title> pairs
    local out="[" sep=""
    while [[ $# -gt 0 ]]; do
        out+="$sep$(python3 -c 'import json,sys; print(json.dumps({"number": int(sys.argv[1]), "title": sys.argv[2]}))' "$1" "$2")"
        sep=","; shift 2
    done
    printf '%s]\n' "$out" > "$work/issues.json"
}
reset() { rm -f "$work/issues.json" "$work/fail_pattern" "$work/rstate/"*; }

# ── threshold: both sides of 1200s ───────────────────────────────────────
reset; stale 1190; run
expect "1190s old (under 1200s): run succeeds" 0 "$RC"
expect "1190s old: no issue filed" 0 "$(calls 'POST .*/issues$')"

reset; stale 1210; run
expect "1210s old (over 1200s): run succeeds" 0 "$RC"
expect "1210s old: one stale-timer issue filed" 1 "$(calls 'POST .*/repos/deanmak13/vm-setup/issues$')"
expect "filing records the last-notification time" 1 "$([[ -s $work/rstate/liveness-alert-last-comment ]] && echo 1 || echo 0)"

reset; rm -f "$work/lstate/streak.tsv"; run
expect "no state file at all counts as stale: issue filed" 1 "$(calls 'POST .*/issues$')"
touch "$work/lstate/streak.tsv"

# ── comment throttle ─────────────────────────────────────────────────────
reset; open_issues 21 "$STALE_TITLE"; stale 1300; run
expect "open issue, no prior comment: comments" 1 "$(calls 'POST .*/issues/21/comments')"
expect "open issue: never files a second issue" 0 "$(calls 'POST .*/issues$')"
run
expect "second stale run within the hour: comment throttled" 0 "$(calls 'POST .*/issues/21/comments')"
expect "throttled run still succeeds" 0 "$RC"
echo $(( $(date +%s) - 3700 )) > "$work/rstate/liveness-alert-last-comment"
run
expect "an hour after the last comment: comments again" 1 "$(calls 'POST .*/issues/21/comments')"

# ── search failure is not "no match" ────────────────────────────────────
reset; stale 1300; echo 'GET .*/issues\?' > "$work/fail_pattern"; run
expect "search fails while stale: no duplicate issue filed" 0 "$(calls 'POST .*/issues$')"
expect "search fails while stale: run exits non-zero" 1 "$RC"
expect "search failure is logged" 1 "$(grep -c 'FAILED to search open issues' "$work/reaper.log" || true)"

reset; stale 1300; printf '{"message":"Bad credentials"}\n' > "$work/issues.json"; run
expect "search returns an error object: no duplicate issue filed" 0 "$(calls 'POST .*/issues$')"
expect "search returns an error object: run exits non-zero" 1 "$RC"

reset; touch "$work/lstate/streak.tsv"; echo 'GET .*/issues\?' > "$work/fail_pattern"; run
expect "search fails while fresh: run exits non-zero (cannot check for an issue to close)" 1 "$RC"

# ── delivery failures fail the run ───────────────────────────────────────
reset; stale 1300; echo '.' > "$work/fail_pattern"; run
expect "every GitHub call fails: run exits non-zero" 1 "$RC"

reset; stale 1300; echo 'POST .*/issues$' > "$work/fail_pattern"; run
expect "filing fails: run exits non-zero" 1 "$RC"
expect "filing failure is logged" 1 "$(grep -c 'FAILED to file liveness-timer-stale issue' "$work/reaper.log" || true)"

reset; open_issues 21 "$STALE_TITLE"; stale 1300; echo 'POST .*/comments' > "$work/fail_pattern"; run
expect "comment fails: run exits non-zero" 1 "$RC"
expect "failed comment does not start the throttle window" 0 "$([[ -s $work/rstate/liveness-alert-last-comment ]] && echo 1 || echo 0)"

# ── recovery closes the stale-timer issue ────────────────────────────────
reset; open_issues 21 "$STALE_TITLE"; touch "$work/lstate/streak.tsv"; run
expect "fresh again with issue open: closes it" 1 "$(calls 'PATCH .*/issues/21$')"
expect "fresh again: run succeeds" 0 "$RC"

reset; open_issues 21 "$STALE_TITLE"; touch "$work/lstate/streak.tsv"; echo 'PATCH' > "$work/fail_pattern"; run
expect "close fails: run exits non-zero" 1 "$RC"

# ── --alert-repo is honoured ─────────────────────────────────────────────
reset; stale 1300; run "$work/config-alt"
expect "--alert-repo my-alerts: issue filed there" 1 "$(calls 'POST .*/repos/deanmak13/my-alerts/issues$')"
expect "--alert-repo my-alerts: nothing sent to vm-setup" 0 "$(calls '/repos/deanmak13/vm-setup/')"

# ── the reaper's own OnFailure issue closes only after 2 healthy runs ────
reset; open_issues 30 "$FAILURE_TITLE"; touch "$work/lstate/streak.tsv"; run
expect "first healthy run: OnFailure issue not closed yet" 0 "$(calls 'PATCH .*/issues/30$')"
run
expect "second healthy run: OnFailure issue closed" 1 "$(calls 'PATCH .*/issues/30$')"
reset; open_issues 30 "$FAILURE_TITLE"; touch "$work/lstate/streak.tsv"; run
echo 'GET .*/issues\?' > "$work/fail_pattern"; run; rm -f "$work/fail_pattern"; run
expect "a failed run in between resets the healthy streak" 0 "$(calls 'PATCH .*/issues/30$')"

# ── installer wiring ─────────────────────────────────────────────────────
expect "runner-reaper.service declares its OnFailure unit" 1 \
    "$(grep -c '^OnFailure=runner-failure-alert@runner-reaper.service$' "$INSTALLER" || true)"
expect "the installer installs bin/runner-reaper and the failure-alert program + template unit" 3 \
    "$(grep -cE '^install -m [0-9]+ "\$REPO_DIR/(bin/runner-reaper|bin/runner-failure-alert|systemd/runner-failure-alert@.service)"' "$INSTALLER" || true)"
expect "the failure-alert program files the title the reaper later closes" 1 \
    "$(grep -cF "TITLE=\"$FAILURE_TITLE\"" "$FAILURE_ALERT" || true)"
expect "the reaper closes that same title" 1 "$(grep -cF "REAPER_FAILURE_TITLE=\"$FAILURE_TITLE\"" "$REAPER_BIN" || true)"
inst_rc=0; inst_out=$(bash "$INSTALLER" --token-file "$work/token" --alert-repo 'a/b' 2>&1) || inst_rc=$?
expect "installer rejects an --alert-repo with a slash" 1 "$(( inst_rc != 0 && $(grep -c 'bare repo name' <<< "$inst_out") ))"
inst_rc=0; inst_out=$(bash "$INSTALLER" --token-file "$work/token" --grace-seconds x 2>&1) || inst_rc=$?
expect "installer rejects a non-numeric --grace-seconds" 1 "$(( inst_rc != 0 && $(grep -c 'non-negative integer' <<< "$inst_out") ))"
inst_rc=0; inst_out=$(bash "$INSTALLER" --bogus 2>&1) || inst_rc=$?
expect "installer rejects an unknown argument" 1 "$(( inst_rc != 0 && $(grep -c 'Unknown argument' <<< "$inst_out") ))"
inst_rc=0; inst_out=$(bash "$INSTALLER" 2>&1) || inst_rc=$?
expect "installer requires --token-file" 1 "$(( inst_rc != 0 && $(grep -c 'token-file is required' <<< "$inst_out") ))"
if [[ $EUID -ne 0 ]]; then
    inst_rc=0; inst_out=$(bash "$INSTALLER" --token-file "$work/token" 2>&1) || inst_rc=$?
    expect "installer refuses to run as non-root after validating" 1 "$(( inst_rc != 0 && $(grep -c 'must be run as root' <<< "$inst_out") ))"
fi
printf 'GRACE=soon\n' > "$work/config-bad"
run "$work/config-bad"
expect "a non-numeric GRACE in the config file stops the reaper (exit 2)" 2 "$RC"

# ── the token never leaks ────────────────────────────────────────────────
expect "token never on curl's command line" 0 "$(grep -c -- "$TOKEN_VALUE" "$work/curl.argv" || true)"
expect "the token header file is removed on exit (nothing left in TMPDIR)" "" "$(ls -A "$work/tmp")"
expect "runner-reaper.service runs with a private /tmp" 1 \
    "$(sed -n '/runner-reaper\.service [<]/,/^UNIT$/p' "$INSTALLER" | grep -c '^PrivateTmp=yes$' || true)"
expect "token never in the reaper log" 0 "$(grep -c -- "$TOKEN_VALUE" "$work/reaper.log" || true)"

exit "$fail"
