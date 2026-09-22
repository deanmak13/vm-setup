#!/usr/bin/env bash
# tests/runner-reaper-crosswatch.test.sh — runner-reaper's cross-watch on
# runner-liveness-check's state file, run end to end: the INSTALLED script's
# own source (extracted from runner-reaper.sh, not copied here) with its
# paths pointed at a temp dir and curl/ps/logger/systemctl stubbed on PATH.
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
REAPER_SRC="${REAPER_SRC:-$REPO_DIR/runner-reaper.sh}"

fail=0
# expect <description> <expected> <actual>
expect() {
    local verdict=ok
    [[ "$2" == "$3" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %q (expected: %q)\n' "$verdict" "$1" "$3" "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stub" "$work/rstate" "$work/lstate"
TOKEN_VALUE="tok-SECRET-$$"
printf '%s\n' "$TOKEN_VALUE" > "$work/token"

# ── the installed reaper, paths redirected into $work ────────────────────
build_reaper() {  # <alert-repo> <out>
    sed -n '\|^cat > /usr/local/bin/runner-reaper |,/^SCRIPT$/p' "$REAPER_SRC" | sed '1d;$d' \
        | sed "s|__GRACE__|600|; s|__ALERT_REPO__|$1|
               s|^TOKEN_FILE_PATH=.*|TOKEN_FILE_PATH=$work/token|
               s|^LOG=.*|LOG=$work/reaper.log|
               s|^STATE_DIR=.*|STATE_DIR=$work/rstate|
               s|^LIVENESS_STATE_FILE=.*|LIVENESS_STATE_FILE=$work/lstate/streak.tsv|" > "$2"
}
build_reaper vm-setup "$work/reaper"
build_reaper my-alerts "$work/reaper-alt"

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
run() {  # [script] — one reaper run; sets RC, leaves curl.calls/reaper.log for inspection
    : > "$work/curl.calls"; : > "$work/reaper.log"
    RC=0
    PATH="$work/stub:$PATH" bash "${1:-$work/reaper}" >/dev/null 2>&1 || RC=$?
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
reset; stale 1300; run "$work/reaper-alt"
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
    "$(grep -c '^OnFailure=runner-reaper-failure-alert.service$' "$REAPER_SRC" || true)"
expect "the failure-alert unit's ExecStart is installed" 1 \
    "$(grep -c '^ExecStart=/usr/local/bin/runner-reaper-failure-alert$' "$REAPER_SRC" || true)"
expect "the failure-alert script files the title the reaper later closes" 2 \
    "$(grep -cF "\"$FAILURE_TITLE\"" "$REAPER_SRC" || true)"
expect "the installer accepts --alert-repo" 1 "$(grep -c -- '--alert-repo) ALERT_REPO=' "$REAPER_SRC" || true)"

# ── the token never leaks ────────────────────────────────────────────────
expect "token never on curl's command line" 0 "$(grep -c -- "$TOKEN_VALUE" "$work/curl.argv" || true)"
expect "token never in the reaper log" 0 "$(grep -c -- "$TOKEN_VALUE" "$work/reaper.log" || true)"

exit "$fail"
