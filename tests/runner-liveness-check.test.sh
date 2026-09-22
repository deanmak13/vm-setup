#!/usr/bin/env bash
# tests/runner-liveness-check.test.sh — runner-liveness-check, the INSTALLED
# script's own source (extracted from runner-liveness-check.sh), run two ways:
#   1. its built-in --self-test (fixture scenarios through run_one_tick);
#   2. the LIVE path end to end — real host_inventory/jq/listener checks and
#      the real top-level dispatch and exit code — with paths pointed at a
#      temp dir and curl/ps/systemctl/logger stubbed on PATH. No network, no
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
CHECK_SRC="${CHECK_SRC:-$REPO_DIR/runner-liveness-check.sh}"

fail=0
# expect <description> <expected> <actual>
expect() {
    local verdict=ok
    [[ "$2" == "$3" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %q (expected: %q)\n' "$verdict" "$1" "$3" "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stub" "$work/state"
printf 'tok-test\n' > "$work/token"

sed -n '\|^cat > /usr/local/bin/runner-liveness-check |,/^SCRIPT$/p' "$CHECK_SRC" | sed '1d;$d' \
    | sed "s|__ALERT_REPO__|vm-setup|; s|__DEBOUNCE_TICKS__|2|; s|__QUEUED_ALERT_GRACE__|1500|
           s|^TOKEN_FILE_PATH=.*|TOKEN_FILE_PATH=$work/token|
           s|^LOG=.*|LOG=$work/check.log|
           s|^STATE_DIR=.*|STATE_DIR=$work/state|
           s|^RUNNER_DIR_GLOB=.*|RUNNER_DIR_GLOB=\"$work/runners/actions-runner-*\"|" > "$work/check"

# ── 1. the built-in self-test ────────────────────────────────────────────
st_rc=0
st_out=$(bash "$work/check" --self-test 2>&1) || st_rc=$?
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
    PATH="$work/stub:$PATH" bash "$work/check" >/dev/null 2>&1 || RC=$?
}
calls() { grep -c -- "$1" "$work/curl.calls" || true; }
reset() { : > "$work/check.log"; rm -f "$work/issues.json" "$work/fail_pattern" "$work/listener_up" "$work/runners_"*.json "$work/state/"*; }
online() { printf '{"runners":[{"name":"pneuma-portal-contabo","status":"%s"}]}\n' "$1" > "$work/runners_pneuma-portal_p1.json"; }

# healthy baseline
reset; touch "$work/listener_up"; online online; run
expect "healthy tick: exits 0" 0 "$RC"
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

exit "$fail"
