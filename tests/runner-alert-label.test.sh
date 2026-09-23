#!/usr/bin/env bash
# tests/runner-alert-label.test.sh — bin/runner-alert-label ensures the
# `runner-liveness` label every watchdog's issue search filters on exists in the
# alert repo, idempotently, and fails loudly when it cannot; both installers run
# it (and abort on failure) before starting their timers. curl is stubbed: GET
# answers $work/get_code, POST answers $work/post_code.
#
# Run: bash tests/runner-alert-label.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
LABEL_BIN="${LABEL_BIN:-$REPO_DIR/bin/runner-alert-label}"

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
printf '%s\n' '#!/usr/bin/env bash' "W=$work" \
    'url=""; method=GET; prev=""' \
    'for a in "$@"; do case "$a" in https://*) url="$a";; esac; [[ "$prev" == "-X" ]] && method="$a"; prev="$a"; done' \
    'echo "$method $url" >> "$W/curl.calls"; echo "$*" >> "$W/curl.argv"' \
    'if [[ "$method" == GET ]]; then cat "$W/get_code"; else cat "$W/post_code"; fi' > "$work/stub/curl"
chmod +x "$work/stub/curl"

RC=0
run() {  # <get-code> <post-code> [args...]
    printf '%s' "$1" > "$work/get_code"; printf '%s' "$2" > "$work/post_code"; shift 2
    : > "$work/curl.calls"
    RC=0
    TMPDIR="$work/tmp" PATH="$work/stub:$PATH" bash "$LABEL_BIN" "$@" >/dev/null 2>&1 || RC=$?
}
calls() { grep -c -- "$1" "$work/curl.calls" || true; }

run 200 000 "$work/token" vm-setup
expect "label exists: exit 0" 0 "$RC"
expect "label exists: nothing created" 0 "$(calls POST)"
expect "label looked up in the alert repo" 1 "$(calls 'GET https://api.github.com/repos/deanmak13/vm-setup/labels/runner-liveness$')"

run 404 201 "$work/token" vm-setup
expect "label missing: created, exit 0" "0 1" "$RC $(calls 'POST https://api.github.com/repos/deanmak13/vm-setup/labels$')"

run 404 422 "$work/token" vm-setup
expect "created concurrently (422): exit 0" 0 "$RC"

run 404 403 "$work/token" vm-setup
expect "cannot create (403): exit 1" 1 "$RC"

run 401 000 "$work/token" vm-setup
expect "lookup fails (401): exit 1, nothing created" "1 0" "$RC $(calls POST)"

run 200 000 "$work/token" 'a/b'
expect "alert repo with a slash: usage error" 2 "$RC"
run 200 000
expect "no arguments: usage error" 2 "$RC"
run 200 000 "$work/missing" vm-setup
expect "missing token file: exit 1 without calling GitHub" "1 0" "$RC $(grep -c . "$work/curl.calls" || true)"

expect "token header file removed on exit" "" "$(ls -A "$work/tmp")"
expect "token never on curl's command line" 0 "$(grep -c tok-SECRET "$work/curl.argv" || true)"

for inst in runner-reaper.sh runner-liveness-check.sh; do
    expect "$inst installs and runs runner-alert-label (aborting on failure) before enabling its timer" 1 \
        "$(awk '/bin\/runner-alert-label"? /{seen=1} /systemctl enable --now/{print seen+0; exit}' "$REPO_DIR/$inst")"
    expect "$inst aborts if the label cannot be ensured" 1 \
        "$(grep -A1 '^/usr/local/bin/runner-alert-label ' "$REPO_DIR/$inst" | grep -c '^    || err ' || true)"
done

exit "$fail"
