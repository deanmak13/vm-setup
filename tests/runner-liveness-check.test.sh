#!/usr/bin/env bash
# tests/runner-liveness-check.test.sh — bin/runner-liveness-check itself (so
# kcov measures it), run two ways:
#   1. its built-in --self-test (fixture scenarios through run_one_tick);
#   2. the LIVE path end to end — real host_inventory/jq/listener checks and
#      the real top-level dispatch and exit code — with paths pointed at a
#      temp dir through a fixture RUNNER_LIVENESS_CONFIG and
#      curl/ps/systemctl/logger stubbed on PATH. No network, no
#      root, no host state.
# The live scenarios cover what only the dispatch can show (round-3 review of
# vm-setup#9): a persistently failing issue search must exit non-zero and
# never file a duplicate (N5, finding 4); a ghost runner survives its repo's
# failed fetch (N4); a failed heartbeat write fails the run (finding 4); a
# runner on page 2 of /actions/runners is not "deregistered" (finding 6).
#
# Run: bash tests/runner-liveness-check.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
CHECK_BIN="${CHECK_BIN:-$REPO_DIR/bin/runner-liveness-check}"
INSTALLER="$REPO_DIR/runner-liveness-check.sh"

fail=0
# expect <description> <expected> <actual>
expect() {
    local verdict=ok
    [[ "$2" == "$3" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %q (expected: %q)\n' "$verdict" "$1" "$3" "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stub" "$work/state" "$work/tmp"
printf 'tok-test\n' > "$work/token"

printf '%s\n' "ALERT_REPO=vm-setup" "DEBOUNCE_TICKS=2" "QUEUED_ALERT_GRACE=1500" \
    "TOKEN_FILE_PATH=$work/token" "LOG=$work/check.log" "STATE_DIR=$work/state" \
    "RUNNER_DIR_GLOB=\"$work/runners/actions-runner-*\"" > "$work/config"
export RUNNER_LIVENESS_CONFIG="$work/config"

# ── 1. the built-in self-test ────────────────────────────────────────────
st_rc=0
st_out=$(bash "$CHECK_BIN" --self-test 2>&1) || st_rc=$?
expect "--self-test exits 0" 0 "$st_rc"
expect "--self-test reports no failed assertion" 0 "$(grep -c 'FAIL:' <<< "$st_out" || true)"

# ── 2. the live path ─────────────────────────────────────────────────────
RUNNER_DIR="$work/runners/actions-runner-pneuma-portal-contabo"
mkdir -p "$RUNNER_DIR/bin.2.337.0"
printf '{"agentName":"pneuma-portal-contabo","gitHubUrl":"https://github.com/deanmak13/pneuma-portal"}\n' > "$RUNNER_DIR/.runner"

# curl: records "METHOD URL"; fails when it matches $work/fail_pattern;
# /actions/runners pages come from runners_<repo>_p<page>.json (absent = empty).
printf '%s\n' '#!/usr/bin/env bash' \
    "W=$work" \
    'url=""; method=GET; prev=""' \
    'for a in "$@"; do case "$a" in https://*) url="$a";; esac; [[ "$prev" == "-X" ]] && method="$a"; prev="$a"; done' \
    'echo "$method $url" >> "$W/curl.calls"' \
    'if [[ -s "$W/fail_pattern" ]] && [[ "$method $url" =~ $(cat "$W/fail_pattern") ]]; then exit 22; fi' \
    'case "$url" in' \
    '  */actions/runners*) r=${url%%/actions/runners*}; r=${r##*/}; p=1; [[ "$url" =~ [\&?]page=([0-9]+) ]] && p=${BASH_REMATCH[1]}' \
    '                      if [[ -f "$W/runners_${r}_p$p.json" ]]; then cat "$W/runners_${r}_p$p.json"; else echo "{\"runners\":[]}"; fi ;;' \
    '  */actions/runs*) echo "{\"workflow_runs\":[],\"total_count\":0}" ;;' \
    '  *"/issues?"*) if [[ -f "$W/issues.json" ]]; then cat "$W/issues.json"; else echo "[]"; fi ;;' \
    '  */issues) echo "{\"number\": 99}" ;;' \
    '  *) echo "{}" ;;' \
    'esac' > "$work/stub/curl"
# ps: a Runner.Listener under the runner dir exists only while $work/listener_up does.
printf '%s\n' '#!/usr/bin/env bash' "[[ -f $work/listener_up ]] && echo '$RUNNER_DIR/bin.2.337.0/Runner.Listener run'" 'exit 0' > "$work/stub/ps"
printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in *LoadState*) echo loaded ;; *ActiveState*) echo active ;; esac' > "$work/stub/systemctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/stub/logger"
chmod +x "$work/stub/"*

RC=0
run() {
    : > "$work/curl.calls"
    RC=0
    TMPDIR="$work/tmp" PATH="$work/stub:$PATH" bash "$CHECK_BIN" >/dev/null 2>&1 || RC=$?
}
calls() { grep -c -- "$1" "$work/curl.calls" || true; }
reset() { : > "$work/check.log"; rm -f "$work/issues.json" "$work/fail_pattern" "$work/listener_up" "$work/runners_"*.json "$work/state/"*; }
online() { printf '{"runners":[{"name":"pneuma-portal-contabo","status":"%s"}]}\n' "$1" > "$work/runners_pneuma-portal_p1.json"; }

# healthy baseline
reset; touch "$work/listener_up"; online online; run
expect "healthy tick: exits 0" 0 "$RC"
expect "the token header file is removed on exit (nothing left in TMPDIR)" "" "$(ls -A "$work/tmp")"
expect "the token is never written under STATE_DIR" 0 "$(grep -rlF tok-test "$work/state" | wc -l)"
expect "healthy tick: files only the heartbeat issue" 1 "$(calls 'POST .*/issues$')"

# N5 + finding 4: a search that fails every tick
reset; online offline; echo 'GET .*/issues\?' > "$work/fail_pattern"; run; rc1=$RC; posts1=$(calls 'POST .*/issues$'); run
expect "search failing, tick 1: exits non-zero" 1 "$([[ $rc1 -ne 0 ]] && echo 1 || echo 0)"
expect "search failing, tick 2 (wedge alert now due): exits non-zero" 1 "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"
expect "search failing: no issue ever POSTed (no duplicates)" 0 "$(( posts1 + $(calls 'POST .*/issues$') ))"
expect "search failing: the skip is logged" 1 "$([[ $(grep -c 'open-issue search failed' "$work/check.log") -gt 0 ]] && echo 1 || echo 0)"

# finding 4: heartbeat write fails, everything else healthy
reset; touch "$work/listener_up"; online online
printf '[{"number": 5, "title": "[runner-liveness] heartbeat"}]\n' > "$work/issues.json"
echo 'PATCH .*/issues/5$' > "$work/fail_pattern"; run
expect "heartbeat PATCH fails: exits non-zero" 1 "$([[ $RC -ne 0 ]] && echo 1 || echo 0)"

# N4: a tracked ghost survives a tick where its repo's runner fetch fails
reset; touch "$work/listener_up"; online online
printf 'ghost:pneuma-ops:orphan\t3\tdead\t77\t0\t0\n' > "$work/state/streak.tsv"
echo 'pneuma-ops/actions/runners' > "$work/fail_pattern"; run
expect "ghost row kept (state + issue #77) across its repo's failed fetch" "ghost:pneuma-ops:orphan dead 77" \
    "$(awk -F'\t' '$1 ~ /^ghost:/ {print $1, $3, $4}' "$work/state/streak.tsv")"

# finding 6: the runner is on page 2 of /actions/runners
reset; touch "$work/listener_up"
python3 -c 'import json; print(json.dumps({"runners": [{"name": "other-%d" % i, "status": "online"} for i in range(100)]}))' > "$work/runners_pneuma-portal_p1.json"
printf '{"runners":[{"name":"pneuma-portal-contabo","status":"online"}]}\n' > "$work/runners_pneuma-portal_p2.json"
run; run
expect "runner on page 2: requested with per_page=100" 1 "$([[ $(calls 'pneuma-portal/actions/runners?per_page=100&page=2') -gt 0 ]] && echo 1 || echo 0)"
expect "runner on page 2: tracked healthy, not deregistered" "healthy" \
    "$(awk -F'\t' '$1 == "runner:pneuma-portal:pneuma-portal-contabo" {print $3}' "$work/state/streak.tsv")"

# ── config and installer validation ──────────────────────────────────────
printf 'DEBOUNCE_TICKS=0\n' > "$work/config-bad"
rc=0; RUNNER_LIVENESS_CONFIG="$work/config-bad" bash "$CHECK_BIN" >/dev/null 2>&1 || rc=$?
expect "DEBOUNCE_TICKS=0 in the config file stops the checker (exit 2)" 2 "$rc"
printf 'ALERT_REPO=a/b\n' > "$work/config-bad"
rc=0; RUNNER_LIVENESS_CONFIG="$work/config-bad" bash "$CHECK_BIN" >/dev/null 2>&1 || rc=$?
expect "ALERT_REPO with a slash in the config file stops the checker (exit 2)" 2 "$rc"
printf 'QUEUED_ALERT_GRACE=later\n' > "$work/config-bad"
rc=0; RUNNER_LIVENESS_CONFIG="$work/config-bad" bash "$CHECK_BIN" >/dev/null 2>&1 || rc=$?
expect "a non-numeric QUEUED_ALERT_GRACE stops the checker (exit 2)" 2 "$rc"
rc=0; RUNNER_LIVENESS_CONFIG="$work/config-bad" bash "$CHECK_BIN" --self-test >/dev/null 2>&1 || rc=$?
expect "--self-test ignores the config file (runs on its own defaults)" 0 "$rc"
for args in "--alert-repo a/b" "--debounce-ticks 0" "--queued-alert-grace-seconds x" "--bogus"; do
    rc=0; out=$(bash "$INSTALLER" $args 2>&1) || rc=$?
    expect "installer rejects '$args' before touching the host" 1 "$(( rc != 0 && $(grep -c 'ERROR' <<< "$out") ))"
done
if [[ $EUID -ne 0 ]]; then
    rc=0; out=$(bash "$INSTALLER" 2>&1) || rc=$?
    expect "installer refuses to run as non-root after validating" 1 "$(( rc != 0 && $(grep -c 'must be run as root' <<< "$out") ))"
fi
expect "runner-liveness-check.service runs with a private /tmp" 1 \
    "$(sed -n '/runner-liveness-check.service <</,/^UNIT$/p' "$INSTALLER" | grep -c '^PrivateTmp=yes$' || true)"
expect "runner-liveness-check.service declares its OnFailure unit" 1 \
    "$(grep -c '^OnFailure=runner-failure-alert@runner-liveness-check.service$' "$INSTALLER" || true)"

exit "$fail"
