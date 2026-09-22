#!/usr/bin/env bash
# tests/runner-failure-alert.test.sh — bin/runner-failure-alert, the OnFailure=
# meta-alert shared by runner-reaper and runner-liveness-check, run against a
# stubbed curl with a fixture RUNNER_FAILURE_ALERT_CONFIG: files one issue when
# none is open, comments at most once an hour (by the issue's own updated_at),
# exits non-zero whenever it cannot deliver, never leaves the token behind, and
# files exactly the titles the two programs later close.
#
# Run: bash tests/runner-failure-alert.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
ALERT_BIN="${ALERT_BIN:-$REPO_DIR/bin/runner-failure-alert}"

fail=0
# expect <description> <expected> <actual>
expect() {
    local verdict=ok
    [[ "$2" == "$3" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %q (expected: %q)\n' "$verdict" "$1" "$3" "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stub" "$work/tmp"
printf 'tok-SECRET\n' > "$work/token"
printf '%s\n' "ALERT_REPO=vm-setup" "TOKEN_FILE_PATH=$work/token" > "$work/config"

printf '%s\n' '#!/usr/bin/env bash' "W=$work" \
    'url=""; method=GET; prev=""' \
    'for a in "$@"; do case "$a" in https://*) url="$a";; esac; [[ "$prev" == "-X" ]] && method="$a"; prev="$a"; done' \
    'echo "$method $url" >> "$W/curl.calls"; echo "$*" >> "$W/curl.argv"' \
    'if [[ -s "$W/fail_pattern" ]] && [[ "$method $url" =~ $(cat "$W/fail_pattern") ]]; then exit 22; fi' \
    'case "$url" in' \
    '  *"/issues?"*) if [[ -f "$W/issues.json" ]]; then cat "$W/issues.json"; else echo "[]"; fi ;;' \
    '  *) echo "{\"number\": 99}" ;;' \
    'esac' > "$work/stub/curl"
chmod +x "$work/stub/"*

REAPER_TITLE="[runner-reaper] runner-reaper failed (crash or undelivered alert)"
CHECK_TITLE="[runner-liveness] the liveness checker itself failed to run"

RC=0
run() {  # <program> [config]
    : > "$work/curl.calls"
    RC=0
    RUNNER_FAILURE_ALERT_CONFIG="${2:-$work/config}" TMPDIR="$work/tmp" PATH="$work/stub:$PATH" \
        bash "$ALERT_BIN" "$1" >/dev/null 2>&1 || RC=$?
}
calls() { grep -c -- "$1" "$work/curl.calls" || true; }
open_issue() {  # <number> <title> <updated-seconds-ago>
    python3 -c '
import json, sys
from datetime import datetime, timezone, timedelta
t = (datetime.now(timezone.utc) - timedelta(seconds=int(sys.argv[3]))).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps([{"number": int(sys.argv[1]), "title": sys.argv[2], "updated_at": t}]))' "$@" > "$work/issues.json"
}
reset() { rm -f "$work/issues.json" "$work/fail_pattern"; }

for prog in runner-reaper runner-liveness-check; do
    reset; run "$prog"
    expect "$prog: no open issue -> files one" 1 "$(calls 'POST .*/repos/deanmak13/vm-setup/issues$')"
    expect "$prog: filing exits 0" 0 "$RC"
done

reset; open_issue 40 "$REAPER_TITLE" 600; run runner-reaper
expect "issue updated 10 minutes ago: no comment" 0 "$(calls 'POST .*/comments')"
expect "issue updated 10 minutes ago: no duplicate either" 0 "$(calls 'POST .*/issues$')"
expect "throttled run exits 0" 0 "$RC"

reset; open_issue 40 "$REAPER_TITLE" 7200; run runner-reaper
expect "issue updated 2 hours ago: one 'still failing' comment" 1 "$(calls 'POST .*/issues/40/comments')"

reset; open_issue 41 "$CHECK_TITLE" 3700; run runner-liveness-check
expect "liveness-check title matched: comments on its own issue" 1 "$(calls 'POST .*/issues/41/comments')"

reset; open_issue 41 "$CHECK_TITLE" 7200; run runner-reaper
expect "a different program's issue is not reused: files its own" 1 "$(calls 'POST .*/issues$')"

# ── delivery failures exit non-zero ──────────────────────────────────────
reset; echo 'GET' > "$work/fail_pattern"; run runner-reaper
expect "search fails: exits non-zero" 1 "$(( RC != 0 ))"
expect "search fails: never files a duplicate" 0 "$(calls 'POST')"
reset; printf '{"message":"Bad credentials"}\n' > "$work/issues.json"; run runner-reaper
expect "search returns an error object: exits non-zero, files nothing" "1 0" "$(( RC != 0 )) $(calls 'POST')"
reset; echo 'POST' > "$work/fail_pattern"; run runner-reaper
expect "create fails: exits non-zero" 1 "$(( RC != 0 ))"
reset; open_issue 40 "$REAPER_TITLE" 7200; echo 'POST' > "$work/fail_pattern"; run runner-reaper
expect "comment fails: exits non-zero" 1 "$(( RC != 0 ))"

# ── configuration ────────────────────────────────────────────────────────
reset; printf '%s\n' "ALERT_REPO=my-alerts" "TOKEN_FILE_PATH=$work/token" > "$work/config-alt"; run runner-reaper "$work/config-alt"
expect "ALERT_REPO from the program's config is honoured" 1 "$(calls 'POST .*/repos/deanmak13/my-alerts/issues$')"
reset; printf '%s\n' "TOKEN_FILE_PATH=$work/missing" > "$work/config-bad"; run runner-reaper "$work/config-bad"
expect "missing token file: exits non-zero without calling GitHub" "1 0" "$(( RC != 0 )) $(grep -c . "$work/curl.calls" || true)"
: > "$work/empty-token"; printf '%s\n' "TOKEN_FILE_PATH=$work/empty-token" > "$work/config-bad"; run runner-reaper "$work/config-bad"
expect "empty token file: exits non-zero" 1 "$(( RC != 0 ))"
run bogus
expect "unknown program: usage error (exit 2)" 2 "$RC"

# ── the token never leaks; titles agree with the programs that close them ─
expect "the token header file is removed on exit (nothing left in TMPDIR)" "" "$(ls -A "$work/tmp")"
expect "token never on curl's command line" 0 "$(grep -c tok-SECRET "$work/curl.argv" || true)"
expect "runner-reaper closes the title this files for it" 1 \
    "$(grep -cF "REAPER_FAILURE_TITLE=\"$REAPER_TITLE\"" "$REPO_DIR/bin/runner-reaper" || true)"
expect "runner-liveness-check closes the title this files for it" 1 \
    "$(grep -cF "local title=\"$CHECK_TITLE\"" "$REPO_DIR/bin/runner-liveness-check" || true)"
expect "this program carries both titles" 2 \
    "$(grep -cF -e "TITLE=\"$REAPER_TITLE\"" -e "TITLE=\"$CHECK_TITLE\"" "$ALERT_BIN" || true)"

exit "$fail"
