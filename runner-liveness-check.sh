#!/usr/bin/env bash
# runner-liveness-check.sh — Install a watchdog that ALERTS A HUMAN when a
# self-hosted GitHub Actions runner is wedged, instead of only self-healing.
#
# THE GAP THIS CLOSES (2026-09-08 -> 2026-09-22): both pneuma-deployments
# runners sat wedged for two weeks. `systemctl` reported both units
# "active running" the entire time; GitHub's runners API showed them
# "offline"; nobody was watching either signal. runner-reaper never
# touched them, because reaper only watches Runner.WORKER zombies (a
# worker that outlives its job) — it has no signal at all for a listener
# that never picks up a job in the first place, which is exactly what a
# dead-but-still-running listener looks like. `/var/log/runner-reaper.log`
# itself went quiet for two weeks and nobody was watching it either, so
# the wedge was invisible until a human happened to look. See memory
# notes reference_runner_active_but_dead_listener.md and
# reference_ci_runner_wedge_signature.md for the forensics this reproduces.
#
# THE SIGNATURE THIS SCRIPT DETECTS (confirmed against the live host
# 2026-09-22): a runner's systemd unit is `active`, but GitHub's
# `/actions/runners` API reports that runner `status=offline`. That
# mismatch — host says alive, GitHub says it never heard from it — is the
# ground truth: GitHub's `status` field IS the listener's live heartbeat,
# sampled independently of anything on the host that could itself be
# lying. A second, distinct signature is also covered: the runner's
# systemd UNIT is missing entirely (the whole service was deregistered,
# not just wedged) while GitHub still expects it — the 2026-08-03 failure
# mode from reference_ci_runner_wedge_signature.md.
#
# WHY NOT A DIAGNOSTIC-LOG-STALENESS CHECK (the "no 'Listening for Jobs'
# line in N minutes" signal named in the earliest incident note): probed
# live against a healthy, GitHub-confirmed-online runner on 2026-09-22
# and found legitimate idle gaps up to ~50 minutes between diagnostic log
# writes under this fleet's current broker-based (useV2Flow) runner
# version — the older runner's chattier log cadence does not hold here.
# Gating on log recency alone would either miss real wedges (grace set
# too high) or false-positive constantly (set too low). GitHub's own
# `status` field does not have this problem.
#
# WHY A SEPARATE SCRIPT FROM runner-reaper: reaper SELF-HEALS (restarts
# units) and is deliberately biased toward leaving things alone to avoid
# killing a live build; this script never restarts anything and only
# alerts. Keeping them separate systemd timers/units means a bug or a
# silent failure in one cannot blind the other — the exact class of
# failure that let the September wedge run two weeks undetected. This
# script's own crashes are covered too: its systemd service carries
# `OnFailure=` pointing at a tiny unit that files its own GitHub issue if
# the checker itself ever fails to run.
#
# WHERE IT ALERTS: files/updates a GitHub issue in deanmak13/vm-setup
# (labelled `runner-liveness`), using the SAME GitHub token already
# installed for runner-reaper (classic PAT, `repo` scope — already
# sufficient for issues:write, no new credential). This was chosen over
# routing through the pneuma-deployments Grafana/Pushgateway alerting
# stack (which has a working Slack/Pushover path) because ci-builder is
# NOT a node of the TST k3s cluster and has no network route to its
# in-cluster Pushgateway; the only existing cross-boundary path
# (cloudflared Access -> OpenBao, see ci-builder-openbao-access.md) took
# a one-time Terraform + DNS + Cloudflare Access operator setup that is
# out of scope for a reversible, no-new-infra fix. GitHub issue creation
# needs zero new infrastructure, zero new credentials, and lands directly
# in the notifications of the repo owner (Dean).
#
# Detections are debounced: a mismatch/queue-starvation must be seen on
# DEBOUNCE_TICKS (default 2) consecutive runs of this script before it
# alerts, and must be seen healthy for DEBOUNCE_TICKS consecutive runs
# before the tracking issue is closed — filters a one-tick API/status
# blip in either direction without slowing real detection past ~10-15
# minutes at the default 5-minute timer cadence.
#
# HARDENING PASS (2026-09-22, independent review of the first version):
# the original had six real bugs that would have let a wedge like the
# September one go undetected or auto-close AGAIN:
#   - GitHub API failures (expired token, rate limit, outage) read as
#     "healthy" instead of "unknown", including auto-CLOSING an open
#     alert after two unknown ticks while the runner was still wedged.
#     Fixed: unknown is evaluated first; falls back to the host-only
#     signal (unit active + no listener = dead); otherwise HOLDS the
#     previous state/streak and never resolves on missing evidence.
#   - A missing/expired token, or a tick where every GitHub call failed,
#     exited 0 — so `OnFailure=` (the meta-alert for the watchdog itself
#     dying) never fired. Fixed: exits 2 in both cases.
#   - "Zero queued runs" was treated as "no evidence" and dropped the
#     key entirely — a starvation alert could never auto-resolve once
#     the queue drained. Fixed: zero queued runs = healthy.
#   - The queued-run age used the NEWEST queued run (list default order)
#     instead of the OLDEST — a steady trickle of new queued jobs every
#     <25min would mask an old one sitting behind them forever, which is
#     exactly the two-week pile-up shape. Fixed: pages through queued
#     runs and tracks the oldest. The in-progress gate was also dropped
#     (a single busy runner on a multi-runner repo was masking a stale
#     queued job on the others).
#   - Comments on an already-open issue fired every 5 minutes (~288/day).
#     Fixed: throttled to at most once per hour, tracked in state.
#   - The OnFailure meta-alert created a new issue on every single
#     failure with no dedup, and swallowed its own POST failures. Fixed:
#     searches for an existing open issue first; exits non-zero if it
#     can't file/comment.
# Also fixed: the GitHub token no longer appears in curl argv (visible
# via `ps`/`/proc`) — it's passed via `-H @<headerfile>`; every value
# interpolated into an inline `python3 -c` string now goes through
# sys.argv instead; the installer's sed substitutions use a delimiter
# that can't collide with a `/` in a repo name and validate numeric
# args; an empty host inventory and a GitHub-registered runner with no
# matching host directory are now their own alert conditions.
#
# KNOWN REMAINING GAP: there is no fully independent dead-man's switch —
# if the systemd TIMER itself is stopped/disabled/uninstalled (as
# opposed to the check running and failing, which `OnFailure=` covers),
# nothing currently notices, because the only thing that would notice is
# this same host. A true fix needs an external heartbeat watched from
# somewhere that isn't ci-builder (e.g. a GitHub Actions scheduled
# workflow on a hosted runner polling a heartbeat issue's timestamp) —
# not built here because GitHub-hosted runners are billing-blocked on
# this personal account (see reference_ci_builder_is_four_machines_in_
# one.md). Every live tick DOES update a pinned heartbeat issue's body
# with a fresh timestamp (`[runner-liveness] heartbeat`) so a human can
# glance and see "last seen: N minutes ago" — that half is real, the
# automated staleness alert on top of it is not.
#
# Requires: a GitHub token with `repo` scope. The installer copies it
# from --token-file (falls back to the already-installed reaper token at
# /root/.runner-reaper-token if --token-file is omitted) to its own copy
# at /root/.runner-liveness-token, so this check's credential lifecycle
# is independent of runner-reaper's.
#
# Usage:
#   sudo bash runner-liveness-check.sh [--token-file /path/to/token] \
#       [--alert-repo vm-setup] [--debounce-ticks 2] \
#       [--queued-alert-grace-seconds 1500]
#
# The installed /usr/local/bin/runner-liveness-check also accepts:
#   --dry-run    real ps/systemctl/GitHub-API data, logs what it WOULD
#                file/close, never calls the issues-write endpoints.
#   --self-test  fixture data (zero ps/systemctl/network calls). Exits
#                non-zero on any assertion failure. This is the
#                recurrence-guard proof — run it any time to confirm the
#                detector still catches the incident shape (and every
#                bug found in review) it was built for, entirely offline.

set -euo pipefail

TOKEN_FILE=""
ALERT_REPO="vm-setup"
DEBOUNCE_TICKS=2
QUEUED_ALERT_GRACE=1500

log() { echo "[runner-liveness-check] $*"; }
err() { echo "[runner-liveness-check] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token-file) TOKEN_FILE="$2"; shift 2 ;;
        --alert-repo) ALERT_REPO="$2"; shift 2 ;;
        --debounce-ticks) DEBOUNCE_TICKS="$2"; shift 2 ;;
        --queued-alert-grace-seconds) QUEUED_ALERT_GRACE="$2"; shift 2 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || err "This script must be run as root (use sudo)"
[[ "$ALERT_REPO" =~ ^[A-Za-z0-9._-]+$ ]] || err "--alert-repo must be a bare repo name (no '/', no whitespace): $ALERT_REPO"
[[ "$DEBOUNCE_TICKS" =~ ^[0-9]+$ && "$DEBOUNCE_TICKS" -ge 1 ]] || err "--debounce-ticks must be a positive integer: $DEBOUNCE_TICKS"
[[ "$QUEUED_ALERT_GRACE" =~ ^[0-9]+$ ]] || err "--queued-alert-grace-seconds must be a non-negative integer: $QUEUED_ALERT_GRACE"

if [[ -n "$TOKEN_FILE" ]]; then
    [[ -f "$TOKEN_FILE" ]] || err "--token-file given but does not exist: $TOKEN_FILE"
    install -m 600 "$TOKEN_FILE" /root/.runner-liveness-token
elif [[ -f /root/.runner-reaper-token ]]; then
    install -m 600 /root/.runner-reaper-token /root/.runner-liveness-token
    log "no --token-file given — copied the existing runner-reaper token (same repo scope covers issues:write)"
else
    err "--token-file is required (no existing /root/.runner-reaper-token to copy)"
fi
log "token installed at /root/.runner-liveness-token"

mkdir -p /var/lib/runner-liveness

cat > /usr/local/bin/runner-liveness-check <<'SCRIPT'
#!/usr/bin/env bash
# Alert on wedged GitHub Actions runners. Installed by
# vm-setup/runner-liveness-check.sh. See that file's header for the full
# design rationale — this is the mechanism, not the explanation.
set -uo pipefail

OWNER=deanmak13
ALERT_REPO="__ALERT_REPO__"
DEBOUNCE_TICKS=__DEBOUNCE_TICKS__
QUEUED_ALERT_GRACE=__QUEUED_ALERT_GRACE__
COMMENT_THROTTLE_SECONDS=3600
TOKEN_FILE_PATH=/root/.runner-liveness-token
LOG=/var/log/runner-liveness-check.log
STATE_DIR=/var/lib/runner-liveness
STATE_FILE="$STATE_DIR/streak.tsv"
AUTH_HEADER_FILE="$STATE_DIR/.authheader"
RUNNER_DIR_GLOB="/home/ubuntu/actions-runner-*"

# The fixed repo roster this checker watches for queued-job starvation —
# every self-hosted-runner-capable Pneuma repo, whether or not it
# currently has a runner registered on THIS host.
REPOS="pneuma pneuma-engine pneuma-portal pneuma-deployments pneuma-helm-charts pneuma-proto pneuma-ops pneuma-mem0 pneuma-terraformer pneuma-agent"

MODE="live"
[[ "${1:-}" == "--dry-run" ]] && MODE="dry-run"
[[ "${1:-}" == "--self-test" ]] && MODE="self-test"

TOKEN=""
if [[ "$MODE" != "self-test" ]]; then
    mkdir -p "$STATE_DIR"
    if [[ ! -r "$TOKEN_FILE_PATH" ]]; then
        echo "runner-liveness-check: token file $TOKEN_FILE_PATH missing or unreadable" >&2
        exit 2
    fi
    TOKEN=$(cat "$TOKEN_FILE_PATH")
    if [[ -z "$TOKEN" ]]; then
        echo "runner-liveness-check: token file $TOKEN_FILE_PATH is empty" >&2
        exit 2
    fi
    # Token goes in a header file, not curl argv, so it never shows up in
    # `ps`/`/proc/<pid>/cmdline` for any other user on the box to read.
    ( umask 077; printf 'Authorization: Bearer %s\n' "$TOKEN" > "$AUTH_HEADER_FILE" )
fi

note() {
    if [[ "$MODE" == "self-test" ]]; then echo "  $*"; return; fi
    if [[ "$MODE" == "dry-run" ]]; then echo "$*"; return; fi
    echo "$(date -Is) $*" >> "$LOG"
    logger -t runner-liveness-check "$*"
}

# Per-tick evidence bookkeeping: how many GitHub calls were attempted vs
# failed. If EVERY call failed this tick (expired/rotated token, GitHub
# outage, rate limit), the tick has zero evidence about anything — the
# live/dry-run dispatch at the bottom exits 2 in that case so
# OnFailure= fires instead of silently reporting "all healthy".
TICK_API_TOTAL=0
TICK_API_FAIL=0

api() {
    curl -sf -m 20 -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" "$1"
}

# Wraps api() with the TICK_API_TOTAL/FAIL counters. Only used for the
# DETECTION reads (runner list, queued/in-progress run lists) — not for
# the alerting-side issue create/comment/close calls, which only happen
# after something is already confirmed dead and whose failure is handled
# on its own terms (see file_or_update_issue/resolve_issue).
api_call() {
    TICK_API_TOTAL=$((TICK_API_TOTAL + 1))
    local body
    if body=$(api "$1"); then
        printf '%s' "$body"
        return 0
    fi
    TICK_API_FAIL=$((TICK_API_FAIL + 1))
    return 1
}

# stdin: one ISO8601 timestamp per line -> prints the OLDEST one's age in
# seconds, or -1 if stdin was empty. Pulled out of queue_state() so
# --self-test can exercise this exact computation directly (a fixture
# pipeline can't prove "picks the oldest, not the newest" — that's a
# property of the pagination/reduction code itself).
oldest_age_from_timestamps() {
    python3 -c "
import sys, datetime
oldest = None
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    t = datetime.datetime.fromisoformat(line.replace('Z', '+00:00'))
    if oldest is None or t < oldest:
        oldest = t
if oldest is None:
    print(-1)
else:
    print(int((datetime.datetime.now(datetime.timezone.utc) - oldest).total_seconds()))
"
}

# ============================================================
# Data collection — LIVE path uses real ps/systemctl/curl; self-test
# reads FIXTURE_* associative/plain vars populated by the scenario
# setters near the bottom of this file. The classification/alerting
# pipeline (run_one_tick and everything it calls) is IDENTICAL in every
# mode: self-test exercises the real alerting code, not a parallel copy.
# ============================================================

declare -A FIXTURE_UNIT_STATE      # unit -> active|inactive|failed|not-found
declare -A FIXTURE_LISTENER_ALIVE  # dir -> 1|0
declare -A FIXTURE_GH_STATUS       # "repo/name" -> online|offline (also IS the fixture roster of "runners GitHub reports" for ghost-runner detection)
declare -A FIXTURE_GH_REPO_FAIL    # repo -> 1 to simulate the runners-list API call failing for that repo
declare -A FIXTURE_QUEUED_AGE      # repo -> seconds (unset/-1 = confirmed empty queue)
declare -A FIXTURE_INPROGRESS      # repo -> count (informational only)
declare -A FIXTURE_QUEUE_FAIL      # repo -> 1 to simulate the queued-runs API call failing for that repo
FIXTURE_INVENTORY=""               # lines "repo<TAB>agentName<TAB>dir"

host_inventory() {
    if [[ "$MODE" == "self-test" ]]; then
        [[ -n "$FIXTURE_INVENTORY" ]] && echo "$FIXTURE_INVENTORY"
        return
    fi
    local dir repo agent url
    for dir in $RUNNER_DIR_GLOB; do
        [[ -d "$dir" && -f "$dir/.runner" ]] || continue
        url=$(jq -r '.gitHubUrl // empty' "$dir/.runner" 2>/dev/null) || continue
        [[ "$url" == "https://github.com/$OWNER/"* ]] || continue
        repo="${url##*/}"
        agent=$(jq -r '.agentName // empty' "$dir/.runner" 2>/dev/null) || continue
        [[ -n "$repo" && -n "$agent" ]] || continue
        printf '%s\t%s\t%s\n' "$repo" "$agent" "$dir"
    done
}

unit_state() {
    # $1="$OWNER-$repo" $2=agentName -> active|inactive|failed|not-found
    local unit="actions.runner.$1.$2.service"
    if [[ "$MODE" == "self-test" ]]; then
        echo "${FIXTURE_UNIT_STATE[$unit]:-not-found}"
        return
    fi
    local load_state active_state
    load_state=$(systemctl show "$unit" -p LoadState --value 2>/dev/null || echo "not-found")
    if [[ "$load_state" != "loaded" ]]; then echo "not-found"; return; fi
    active_state=$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || echo "inactive")
    echo "$active_state"
}

listener_alive() {
    # $1=runner install dir -> 0 (alive) or 1 (absent)
    if [[ "$MODE" == "self-test" ]]; then
        [[ "${FIXTURE_LISTENER_ALIVE[$1]:-0}" == "1" ]] && return 0 || return 1
    fi
    ps -eo args | grep -F "$1/bin" | grep -q "[R]unner\.Listener" && return 0 || return 1
}

# Fetches every repo's runner list ONCE per tick (not once per known
# runner — the original called this per host-inventory runner, hitting
# the same /actions/runners endpoint repeatedly) and populates:
#   GH_RUNNER_STATUS["repo/name"] -> status   (every runner GitHub knows about)
#   GH_REPO_OK[repo]              -> 1 ok / 0 this repo's fetch failed this tick
# GH_RUNNER_STATUS doubles as the "what does GitHub think exists" roster
# used for ghost-runner detection (a name with no matching host dir).
declare -A GH_RUNNER_STATUS
declare -A GH_REPO_OK

prefetch_github_runners() {
    GH_RUNNER_STATUS=(); GH_REPO_OK=()
    local repo
    for repo in $REPOS; do
        if [[ "$MODE" == "self-test" ]]; then
            if [[ "${FIXTURE_GH_REPO_FAIL[$repo]:-0}" == "1" ]]; then
                TICK_API_TOTAL=$((TICK_API_TOTAL + 1)); TICK_API_FAIL=$((TICK_API_FAIL + 1))
                GH_REPO_OK[$repo]=0
                continue
            fi
            TICK_API_TOTAL=$((TICK_API_TOTAL + 1))
            GH_REPO_OK[$repo]=1
            local k
            for k in "${!FIXTURE_GH_STATUS[@]}"; do
                [[ "$k" == "$repo/"* ]] && GH_RUNNER_STATUS["$k"]="${FIXTURE_GH_STATUS[$k]}"
            done
            continue
        fi
        local json
        if ! json=$(api_call "https://api.github.com/repos/$OWNER/$repo/actions/runners"); then
            GH_REPO_OK[$repo]=0
            continue
        fi
        GH_REPO_OK[$repo]=1
        while IFS=$'\t' read -r name status; do
            [[ -n "$name" ]] || continue
            GH_RUNNER_STATUS["$repo/$name"]="$status"
        done < <(printf '%s' "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('runners') or []:
    print(f\"{r.get('name','')}\t{r.get('status') or 'unknown'}\")
" 2>/dev/null)
    done
}

gh_runner_status_of() {
    # $1=repo $2=agentName -> online|offline|unknown
    [[ "${GH_REPO_OK[$1]:-0}" == "1" ]] || { echo "unknown"; return; }
    echo "${GH_RUNNER_STATUS[$1/$2]:-unknown}"
}

queue_state() {
    # $1=repo -> "age<TAB>inprog<TAB>ok"
    #   age: -1 = confirmed empty queue (healthy); >=0 = OLDEST queued run's age
    #   inprog: informational only, never gates the decision; -1 = unknown
    #   ok: 1 = evidence usable this tick; 0 = unknown, caller must HOLD
    if [[ "$MODE" == "self-test" ]]; then
        if [[ "${FIXTURE_QUEUE_FAIL[$1]:-0}" == "1" ]]; then
            TICK_API_TOTAL=$((TICK_API_TOTAL + 1)); TICK_API_FAIL=$((TICK_API_FAIL + 1))
            printf '%s\t%s\t%s\n' -1 -1 0
        else
            TICK_API_TOTAL=$((TICK_API_TOTAL + 1))
            printf '%s\t%s\t%s\n' "${FIXTURE_QUEUED_AGE[$1]:--1}" "${FIXTURE_INPROGRESS[$1]:--1}" 1
        fi
        return
    fi
    local page json times n all_times="" qfail=0
    for page in 1 2 3 4 5; do
        if ! json=$(api_call "https://api.github.com/repos/$OWNER/$1/actions/runs?status=queued&per_page=100&page=$page"); then
            qfail=1; break
        fi
        times=$(printf '%s' "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('workflow_runs') or []:
    print(r.get('created_at', ''))
" 2>/dev/null) || { qfail=1; break; }
        n=$(printf '%s\n' "$times" | grep -c . || true)
        [[ -n "$times" ]] && all_times+="$times"$'\n'
        [[ "$n" -lt 100 ]] && break
    done
    if (( qfail )); then
        printf '%s\t%s\t%s\n' -1 -1 0
        return
    fi
    local age
    age=$(printf '%s' "$all_times" | oldest_age_from_timestamps) || age=-1
    local ijson inprog
    if ijson=$(api_call "https://api.github.com/repos/$OWNER/$1/actions/runs?status=in_progress&per_page=1"); then
        inprog=$(printf '%s' "$ijson" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_count',-1))" 2>/dev/null) || inprog=-1
    else
        inprog=-1
    fi
    printf '%s\t%s\t%s\n' "$age" "$inprog" 1
}

# ============================================================
# Debounce + alerting state. STREAK/STATE/ISSUE_NUM/LAST_COMMENT hold "as
# of the start of this tick"; NEW_* accumulate "as of the end" and get
# copied over — the copy is what makes state self-pruning (a key not
# touched this tick just doesn't appear in NEW_* and is dropped).
# ============================================================

declare -A STREAK STATE ISSUE_NUM LAST_COMMENT
declare -A NEW_STREAK NEW_STATE NEW_ISSUE NEW_LAST_COMMENT TICK_ACTIONS

load_state() {
    STREAK=(); STATE=(); ISSUE_NUM=(); LAST_COMMENT=()
    [[ ! -f "$STATE_FILE" ]] && return
    local key streak state issue lastc
    while IFS=$'\t' read -r key streak state issue lastc; do
        STREAK["$key"]="$streak"; STATE["$key"]="$state"
        ISSUE_NUM["$key"]="$issue"; LAST_COMMENT["$key"]="${lastc:-0}"
    done < "$STATE_FILE"
}

commit_tick() {
    STREAK=(); STATE=(); ISSUE_NUM=(); LAST_COMMENT=()
    local key
    for key in "${!NEW_STATE[@]}"; do
        STREAK["$key"]="${NEW_STREAK[$key]}"; STATE["$key"]="${NEW_STATE[$key]}"
        ISSUE_NUM["$key"]="${NEW_ISSUE[$key]:-0}"; LAST_COMMENT["$key"]="${NEW_LAST_COMMENT[$key]:-0}"
    done
    [[ "$MODE" == "live" ]] || return 0
    {
        for key in "${!STATE[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\n' "$key" "${STREAK[$key]}" "${STATE[$key]}" "${ISSUE_NUM[$key]:-0}" "${LAST_COMMENT[$key]:-0}"
        done
    } > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    return 0
}

# Carries a key's PREVIOUS tick values forward unchanged — no streak
# movement, no action fired, and (critically) the key is NOT dropped by
# self-pruning. Used whenever this tick has no usable evidence for a key
# (a GitHub call failed): the debounce state and any open issue survive
# untouched until real evidence is available again.
hold_key() {
    local key="$1"
    NEW_STATE["$key"]="${STATE[$key]:-healthy}"
    NEW_STREAK["$key"]="${STREAK[$key]:-0}"
    NEW_ISSUE["$key"]="${ISSUE_NUM[$key]:-0}"
    NEW_LAST_COMMENT["$key"]="${LAST_COMMENT[$key]:-0}"
}

gh_find_open_issue() {
    # $1=title (exact match) -> issue number or empty
    api "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues?labels=runner-liveness&state=open&per_page=100" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
title = sys.argv[1]
for i in d:
    if i.get('title') == title:
        print(i['number']); break
" "$1" 2>/dev/null
}

file_or_update_issue() {
    # $1=key $2=title $3=body
    local key="$1" title="$2" body="$3" existing="${ISSUE_NUM[$key]:-0}"
    TICK_ACTIONS["$key"]="alert"
    if [[ "$MODE" == "self-test" ]]; then
        note "would file/update issue: $title"
        NEW_ISSUE["$key"]=1
        NEW_LAST_COMMENT["$key"]=1
        return
    fi
    if [[ "$MODE" == "dry-run" ]]; then
        note "DRY-RUN would file/update issue: $title :: $body"
        NEW_ISSUE["$key"]="$existing"
        NEW_LAST_COMMENT["$key"]="${LAST_COMMENT[$key]:-0}"
        return
    fi
    local now_epoch; now_epoch=$(date +%s)
    if [[ "$existing" == "0" ]]; then
        existing=$(gh_find_open_issue "$title")
        [[ -n "$existing" ]] || existing=0
    fi
    if [[ "$existing" != "0" ]]; then
        # Comment on state re-confirmation, but at most once per hour —
        # a 5-minute tick cadence would otherwise post ~288 comments/day
        # on an issue that's just still open.
        local last="${LAST_COMMENT[$key]:-0}"
        if (( now_epoch - last >= COMMENT_THROTTLE_SECONDS )); then
            if curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
                "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing/comments" \
                -d "$(python3 -c "
import json, sys
print(json.dumps({'body': 'still failing: ' + sys.argv[1]}))
" "$body")" >/dev/null 2>&1; then
                note "updated issue #$existing: $title"
                NEW_LAST_COMMENT["$key"]="$now_epoch"
            else
                note "FAILED to comment on issue #$existing: $title"
                NEW_LAST_COMMENT["$key"]="$last"
            fi
        else
            note "issue #$existing already open, comment throttled ($(( now_epoch - last ))s since last, threshold ${COMMENT_THROTTLE_SECONDS}s): $title"
            NEW_LAST_COMMENT["$key"]="$last"
        fi
        NEW_ISSUE["$key"]="$existing"
    else
        local resp num
        resp=$(curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues" \
            -d "$(python3 -c "
import json, sys
print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['runner-liveness']}))
" "$title" "$body")")
        if [[ $? -eq 0 && -n "$resp" ]]; then
            num=$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',0))" 2>/dev/null) || num=0
            NEW_ISSUE["$key"]="$num"
            NEW_LAST_COMMENT["$key"]="$now_epoch"
            note "filed issue #$num: $title"
        else
            NEW_ISSUE["$key"]=0
            NEW_LAST_COMMENT["$key"]=0
            note "FAILED to file issue: $title"
        fi
    fi
}

resolve_issue() {
    # $1=key $2=title
    local key="$1" title="$2" existing="${ISSUE_NUM[$key]:-0}"
    TICK_ACTIONS["$key"]="resolve"
    if [[ "$MODE" == "self-test" ]]; then
        note "would resolve+close issue: $title"
        NEW_ISSUE["$key"]=0
        NEW_LAST_COMMENT["$key"]=0
        return
    fi
    if [[ "$MODE" == "dry-run" ]]; then
        note "DRY-RUN would resolve+close issue: $title"
        NEW_ISSUE["$key"]=0
        NEW_LAST_COMMENT["$key"]=0
        return
    fi
    if [[ "$existing" != "0" ]]; then
        local comment_ok=0 close_ok=0
        curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing/comments" \
            -d '{"body":"resolved: liveness checks are healthy again."}' >/dev/null 2>&1 && comment_ok=1
        curl -sf -m 20 -X PATCH -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing" \
            -d '{"state":"closed"}' >/dev/null 2>&1 && close_ok=1
        if [[ "$close_ok" == "1" ]]; then
            note "resolved+closed issue #$existing: $title (comment_ok=$comment_ok)"
            NEW_ISSUE["$key"]=0
            NEW_LAST_COMMENT["$key"]=0
        else
            # Don't orphan the issue number — a lost PATCH would otherwise
            # leave a real open issue with ISSUE_NUM reset to 0, so the
            # NEXT alert would search-or-create a duplicate instead of
            # finding this one. Keep it and retry closing next healthy tick.
            note "FAILED to close issue #$existing (comment_ok=$comment_ok): $title — will retry next healthy tick"
            NEW_ISSUE["$key"]="$existing"
            NEW_LAST_COMMENT["$key"]="${LAST_COMMENT[$key]:-0}"
        fi
    else
        NEW_ISSUE["$key"]=0
    fi
}

# $1=key $2=is_dead(0/1) $3=title $4=body — advances the debounce streak
# and fires file_or_update_issue/resolve_issue only once the streak
# crosses DEBOUNCE_TICKS in either direction. Callers with no usable
# evidence this tick call hold_key() instead of this function.
evaluate_key() {
    local key="$1" is_dead="$2" title="$3" body="$4"
    local prev_state="${STATE[$key]:-healthy}" prev_streak="${STREAK[$key]:-0}"
    local cur_state="healthy"
    [[ "$is_dead" == "1" ]] && cur_state="dead"

    local streak=1
    [[ "$cur_state" == "$prev_state" ]] && streak=$((prev_streak + 1))
    NEW_STATE["$key"]="$cur_state"
    NEW_STREAK["$key"]="$streak"
    NEW_ISSUE["$key"]="${ISSUE_NUM[$key]:-0}"
    NEW_LAST_COMMENT["$key"]="${LAST_COMMENT[$key]:-0}"

    local already_open="${ISSUE_NUM[$key]:-0}"
    if [[ "$cur_state" == "dead" && "$streak" -ge "$DEBOUNCE_TICKS" ]]; then
        file_or_update_issue "$key" "$title" "$body"
    elif [[ "$cur_state" == "healthy" && "$streak" -ge "$DEBOUNCE_TICKS" && "$already_open" != "0" ]]; then
        resolve_issue "$key" "$title"
    fi
}

# ============================================================
# One tick == everything a single systemd-timer firing does.
# ============================================================

TICK_EXIT_CODE=0

run_one_tick() {
    NEW_STATE=(); NEW_STREAK=(); NEW_ISSUE=(); NEW_LAST_COMMENT=(); TICK_ACTIONS=()
    TICK_API_TOTAL=0; TICK_API_FAIL=0

    declare -A HOST_HAS   # "repo/agent" -> 1, built from host_inventory
    HOST_HAS=()
    local repo agent dir
    while IFS=$'\t' read -r repo agent dir; do
        [[ -n "${repo:-}" ]] || continue
        HOST_HAS["$repo/$agent"]=1
    done < <(host_inventory)

    prefetch_github_runners

    # --- empty-inventory guard: zero runners found on the host at all is
    # itself a failure signature (every install dir gone, or every
    # .runner file unreadable) that would otherwise silently pass every
    # per-runner check by having nothing to iterate. ---
    local inv_is_dead=0
    [[ "${#HOST_HAS[@]}" -eq 0 ]] && inv_is_dead=1
    evaluate_key "inventory:host" "$inv_is_dead" \
        "[runner-liveness] host inventory is empty" \
        "host_inventory() returned zero runners on ci-builder — either every /home/ubuntu/actions-runner-* directory is gone or every .runner file is unreadable. This check cannot see any runner on the host right now."

    # --- per-runner: host state vs GitHub state, unknown evaluated FIRST ---
    while IFS=$'\t' read -r repo agent dir; do
        [[ -n "${repo:-}" ]] || continue
        local unit_state_val gh_status key title body_prefix is_dead evidence listener_note
        unit_state_val=$(unit_state "$OWNER-$repo" "$agent")
        gh_status=$(gh_runner_status_of "$repo" "$agent")
        key="runner:$repo:$agent"
        title="[runner-liveness] $repo/$agent: wedged self-hosted runner"
        body_prefix="Runner install dir: $dir. Remediation: ssh ci-builder; check with systemctl status actions.runner.$OWNER-$repo.$agent.service; if the unit is active but GitHub still shows offline after a manual look, 'systemctl restart actions.runner.$OWNER-$repo.$agent.service' is safe (listener re-registers and picks up queued work within seconds)."

        if [[ "$unit_state_val" != "active" ]]; then
            # Host-only evidence: a unit that isn't active is definitively
            # not serving, independent of whether GitHub is reachable.
            is_dead=1
            evidence="unit=$unit_state_val github_status=$gh_status"
        elif [[ "$gh_status" == "online" ]]; then
            is_dead=0
            evidence="unit=active github_status=online"
        elif [[ "$gh_status" == "offline" ]]; then
            if listener_alive "$dir"; then listener_note="present"; else listener_note="ABSENT"; fi
            is_dead=1
            evidence="unit=active listener=$listener_note github_status=offline"
        else
            # gh_status == unknown (API call failed / token expired /
            # rate limited / runner missing from GitHub's list): do NOT
            # assume healthy. Fall back to the host-only signal — unit
            # active with no listener process is dead regardless of
            # whether GitHub could be asked. Otherwise there's no
            # evidence either way this tick: HOLD, never resolve on it.
            if listener_alive "$dir"; then
                [[ "$MODE" == "dry-run" ]] && note "classify $key: HOLD (github status unknown, listener present, unit active)"
                hold_key "$key"
                continue
            fi
            is_dead=1
            evidence="unit=active listener=ABSENT github_status=unknown(host-fallback)"
        fi

        [[ "$MODE" == "dry-run" ]] && note "classify $key: is_dead=$is_dead $evidence"
        evaluate_key "$key" "$is_dead" "$title" "Host unit $OWNER-$repo.$agent: $evidence. $body_prefix"
    done < <(host_inventory)

    # --- ghost-runner detection: GitHub knows about a runner with no
    # matching host directory (install lost, or should be deregistered). ---
    local ghkey
    for ghkey in "${!GH_RUNNER_STATUS[@]}"; do
        [[ -n "${HOST_HAS[$ghkey]:-}" ]] && continue
        local grepo="${ghkey%%/*}" gname="${ghkey#*/}"
        evaluate_key "ghost:$grepo:$gname" 1 \
            "[runner-liveness] $grepo/$gname: registered on GitHub, no host directory" \
            "GitHub lists runner '$gname' for $grepo (status=${GH_RUNNER_STATUS[$ghkey]}) but no matching /home/ubuntu/actions-runner-* directory exists on ci-builder. Either the host lost its install or the runner should be deregistered on GitHub."
    done

    # --- per-repo queue starvation: OLDEST queued run's age; in_progress
    # is informational only (a single busy runner on a multi-runner repo
    # must not mask a stale queued job sitting behind it). ---
    local repo2 qage inprog qok key2 title2 body2 is_dead2
    for repo2 in $REPOS; do
        read -r qage inprog qok < <(queue_state "$repo2")
        key2="queue:$repo2"
        title2="[runner-liveness] $repo2: queued job with no runner picking it up"
        if [[ "$qok" != "1" ]]; then
            [[ "$MODE" == "dry-run" ]] && note "classify $key2: HOLD (queue API unknown this tick)"
            hold_key "$key2"
            continue
        fi
        if [[ "$qage" == "-1" ]]; then
            is_dead2=0   # confirmed empty queue
        else
            is_dead2=0
            [[ "$qage" -ge "$QUEUED_ALERT_GRACE" ]] && is_dead2=1
        fi
        body2="Repo $repo2: OLDEST queued run is ${qage}s old (in_progress_runs=$inprog, informational only — not required to be zero). "
        body2+="Alert threshold ${QUEUED_ALERT_GRACE}s. Check: gh run list --repo $OWNER/$repo2 --status queued. "
        body2+="If this repo has zero registered runners on ci-builder, register one (reference_contabo_ci_runner_setup)."
        [[ "$MODE" == "dry-run" ]] && note "classify $key2: is_dead=$is_dead2 queued_age=${qage}s in_progress=$inprog"
        evaluate_key "$key2" "$is_dead2" "$title2" "$body2"
    done

    commit_tick

    TICK_EXIT_CODE=0
    if [[ "$TICK_API_TOTAL" -gt 0 && "$TICK_API_TOTAL" -eq "$TICK_API_FAIL" ]]; then
        TICK_EXIT_CODE=2
    fi
}

# Best-effort dead-man's-switch heartbeat: update a single pinned issue's
# body with the current timestamp so a human can glance and see how
# recently the checker actually ran. This does NOT alert on its own if
# the timer stops firing entirely (see the KNOWN REMAINING GAP note at
# the top of vm-setup/runner-liveness-check.sh) — it only makes that
# failure mode observable to someone who looks.
update_heartbeat() {
    [[ "$MODE" == "live" ]] || return 0
    local title="[runner-liveness] heartbeat"
    local existing
    existing=$(gh_find_open_issue "$title") || existing=""
    local body
    body="Last liveness-check tick: $(date -Is). If this stops moving, the runner-liveness-check.timer itself may have stopped — check \`systemctl status runner-liveness-check.timer\` on ci-builder."
    if [[ -n "$existing" ]]; then
        curl -sf -m 20 -X PATCH -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing" \
            -d "$(python3 -c "import json,sys; print(json.dumps({'body': sys.argv[1]}))" "$body")" >/dev/null 2>&1 \
            || note "FAILED to update heartbeat issue #$existing"
    else
        curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues" \
            -d "$(python3 -c "
import json, sys
print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['runner-liveness']}))
" "$title" "$body")" >/dev/null 2>&1 \
            || note "FAILED to create heartbeat issue"
    fi
}

# ============================================================
# --self-test: fixture scenarios reusing run_one_tick unmodified. Every
# scenario here corresponds 1:1 to a bug found in independent review;
# each was confirmed RED under its specific mutation before being fixed.
# ============================================================

self_test() {
    local failures=0

    clear_fixtures() {
        FIXTURE_UNIT_STATE=(); FIXTURE_LISTENER_ALIVE=(); FIXTURE_GH_STATUS=(); FIXTURE_GH_REPO_FAIL=()
        FIXTURE_QUEUED_AGE=(); FIXTURE_INPROGRESS=(); FIXTURE_QUEUE_FAIL=(); FIXTURE_INVENTORY=""
    }
    assert_eq() {
        local got="$1" want="$2" label="$3"
        if [[ "$got" == "$want" ]]; then
            echo "  PASS: $label"
        else
            echo "  FAIL: $label (got '$got', want '$want')"
            failures=$((failures + 1))
        fi
    }
    assert_true() {
        local cond="$1" label="$2"
        if [[ "$cond" == "1" ]]; then
            echo "  PASS: $label"
        else
            echo "  FAIL: $label"
            failures=$((failures + 1))
        fi
    }

    echo "== scenario 1: healthy runner + healthy queue, 3 ticks =="
    for t in 1 2 3; do
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-deployments\tpneuma-deployments-contabo\t/home/ubuntu/actions-runner-pneuma-deployments-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-deployments.pneuma-deployments-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-deployments-contabo"]="1"
        FIXTURE_GH_STATUS["pneuma-deployments/pneuma-deployments-contabo"]="online"
        FIXTURE_QUEUED_AGE["pneuma-deployments"]=-1
        FIXTURE_INPROGRESS["pneuma-deployments"]=0
        run_one_tick
        assert_eq "${TICK_ACTIONS[runner:pneuma-deployments:pneuma-deployments-contabo]:-}" "" "tick $t: no runner action while healthy"
        assert_eq "${TICK_ACTIONS[queue:pneuma-deployments]:-}" "" "tick $t: no queue action while healthy"
        assert_eq "${TICK_ACTIONS[inventory:host]:-}" "" "tick $t: no inventory action with a non-empty inventory"
    done

    echo "== scenario 2: reproduce the 2026-09-08 wedge (unit active, listener absent, GitHub offline) =="
    wedged_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-deployments\tpneuma-deployments-contabo\t/home/ubuntu/actions-runner-pneuma-deployments-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-deployments.pneuma-deployments-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-deployments-contabo"]="0"
        FIXTURE_GH_STATUS["pneuma-deployments/pneuma-deployments-contabo"]="offline"
        FIXTURE_QUEUED_AGE["pneuma-deployments"]=-1
        FIXTURE_INPROGRESS["pneuma-deployments"]=0
    }
    wedged_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-deployments:pneuma-deployments-contabo]:-}" "" "wedge tick 1 (streak 1 < debounce $DEBOUNCE_TICKS): no action yet"
    wedged_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-deployments:pneuma-deployments-contabo]:-}" "alert" "wedge tick 2 (streak reaches debounce): alert fires"
    wedged_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-deployments:pneuma-deployments-contabo]:-}" "alert" "wedge tick 3 (still wedged): alert keeps updating"

    echo "== scenario 2 continued: recovery =="
    healthy_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-deployments\tpneuma-deployments-contabo\t/home/ubuntu/actions-runner-pneuma-deployments-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-deployments.pneuma-deployments-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-deployments-contabo"]="1"
        FIXTURE_GH_STATUS["pneuma-deployments/pneuma-deployments-contabo"]="online"
        FIXTURE_QUEUED_AGE["pneuma-deployments"]=-1
        FIXTURE_INPROGRESS["pneuma-deployments"]=0
    }
    healthy_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-deployments:pneuma-deployments-contabo]:-}" "" "recovery tick 1 (streak 1 < debounce): issue stays open, no action"
    healthy_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-deployments:pneuma-deployments-contabo]:-}" "resolve" "recovery tick 2 (streak reaches debounce): resolve fires"

    echo "== scenario 3: queued job with zero in-progress runs, stale past grace =="
    starved_tick() {
        clear_fixtures
        FIXTURE_QUEUED_AGE["pneuma-helm-charts"]=$((QUEUED_ALERT_GRACE + 60))
        FIXTURE_INPROGRESS["pneuma-helm-charts"]=0
    }
    starved_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[queue:pneuma-helm-charts]:-}" "" "starvation tick 1: below debounce, no action"
    starved_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[queue:pneuma-helm-charts]:-}" "alert" "starvation tick 2: alert fires"

    echo "== scenario 3b: a stuck in-progress run must NOT mask a stale queued run =="
    starved_busy_tick() {
        clear_fixtures
        FIXTURE_QUEUED_AGE["pneuma-engine"]=$((QUEUED_ALERT_GRACE + 300))
        FIXTURE_INPROGRESS["pneuma-engine"]=1   # nonzero — the old bug required this to be 0 to alert
    }
    starved_busy_tick; run_one_tick
    starved_busy_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[queue:pneuma-engine]:-}" "alert" "starvation with 1 in-progress run: alert still fires (in-progress no longer gates)"

    echo "== scenario 4: unknown GitHub status must NOT read as healthy, and must NOT auto-close an open alert =="
    unknown_but_listener_present_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-portal\tpneuma-portal-contabo\t/home/ubuntu/actions-runner-pneuma-portal-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-portal.pneuma-portal-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-portal-contabo"]="1"
        FIXTURE_GH_REPO_FAIL["pneuma-portal"]=1   # simulates an API failure / expired token for this repo
    }
    # First get a real alert open (wedged: active unit, absent listener, confirmed offline).
    portal_wedged_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-portal\tpneuma-portal-contabo\t/home/ubuntu/actions-runner-pneuma-portal-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-portal.pneuma-portal-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-portal-contabo"]="0"
        FIXTURE_GH_STATUS["pneuma-portal/pneuma-portal-contabo"]="offline"
    }
    portal_wedged_tick; run_one_tick
    portal_wedged_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-portal:pneuma-portal-contabo]:-}" "alert" "portal wedge: alert opens as the baseline for this scenario"
    # Now two ticks where GitHub is unreachable but the listener process
    # IS present (host can't confirm healthy on its own). Before the fix,
    # "unknown" fell through to the "unit active" branch => is_dead=0 =>
    # this would auto-resolve after 2 ticks despite no real evidence of
    # recovery. It must instead HOLD.
    unknown_but_listener_present_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-portal:pneuma-portal-contabo]:-}" "" "unknown tick 1 (listener present): HOLD, no resolve"
    unknown_but_listener_present_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-portal:pneuma-portal-contabo]:-}" "" "unknown tick 2 (listener present): still HOLD, NOT auto-closed"
    # A real "healthy" tick right after is a STATE TRANSITION (dead ->
    # healthy), which correctly restarts the debounce streak at 1 — the
    # hold preserved the dead streak, it doesn't grant an instant resolve.
    # It still needs its own DEBOUNCE_TICKS consecutive healthy ticks,
    # same as ordinary recovery (scenario 2).
    healthy_portal_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-portal\tpneuma-portal-contabo\t/home/ubuntu/actions-runner-pneuma-portal-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-portal.pneuma-portal-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-portal-contabo"]="1"
        FIXTURE_GH_STATUS["pneuma-portal/pneuma-portal-contabo"]="online"
    }
    healthy_portal_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-portal:pneuma-portal-contabo]:-}" "" "first real healthy tick after the hold (streak 1 < debounce): issue correctly stays open, no premature resolve"
    healthy_portal_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-portal:pneuma-portal-contabo]:-}" "resolve" "second real healthy tick after the hold: resolve fires on its own full debounce"

    echo "== scenario 5: unknown GitHub status WITH listener absent falls back to host-confirmed dead =="
    unknown_host_dead_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-proto\tpneuma-proto-contabo\t/home/ubuntu/actions-runner-pneuma-proto-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-proto.pneuma-proto-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-proto-contabo"]="0"
        FIXTURE_GH_REPO_FAIL["pneuma-proto"]=1
    }
    unknown_host_dead_tick; run_one_tick
    unknown_host_dead_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-proto:pneuma-proto-contabo]:-}" "alert" "unknown GitHub + no listener: host-fallback still alerts"

    echo "== scenario 6: queue recovery/drain must close an open starvation alert =="
    drain_starved_tick() {
        clear_fixtures
        FIXTURE_QUEUED_AGE["pneuma-mem0"]=$((QUEUED_ALERT_GRACE + 60))
        FIXTURE_INPROGRESS["pneuma-mem0"]=0
    }
    drain_healthy_tick() {
        clear_fixtures
        FIXTURE_QUEUED_AGE["pneuma-mem0"]=-1   # confirmed: queue drained
        FIXTURE_INPROGRESS["pneuma-mem0"]=0
    }
    drain_starved_tick; run_one_tick
    drain_starved_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[queue:pneuma-mem0]:-}" "alert" "queue drain scenario: starvation alert opens first"
    drain_healthy_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[queue:pneuma-mem0]:-}" "" "drain tick 1: below debounce, no action yet"
    drain_healthy_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[queue:pneuma-mem0]:-}" "resolve" "drain tick 2: queue confirmed empty -> resolve fires (old bug: 'continue' dropped this key and it could never close)"

    echo "== scenario 7: unknown queue tick holds state instead of wiping the streak/issue =="
    qhold_starved_tick() {
        clear_fixtures
        FIXTURE_QUEUED_AGE["pneuma-agent"]=$((QUEUED_ALERT_GRACE + 60))
        FIXTURE_INPROGRESS["pneuma-agent"]=0
    }
    qhold_unknown_tick() {
        clear_fixtures
        FIXTURE_QUEUE_FAIL["pneuma-agent"]=1
    }
    qhold_starved_tick; run_one_tick
    qhold_starved_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[queue:pneuma-agent]:-}" "alert" "queue hold scenario: starvation alert opens first"
    qhold_unknown_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[queue:pneuma-agent]:-}" "" "unknown queue tick: HOLD, no new action, issue not dropped"
    qhold_starved_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[queue:pneuma-agent]:-}" "alert" "next real tick still shows dead immediately (streak survived the hold, kept updating the SAME issue)"

    echo "== scenario 8: oldest-vs-newest queued run (direct test of the pagination reduction, not the fixture path) =="
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    recent_iso=$(date -u -d "@$(( $(date +%s) - 120 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-120S +%Y-%m-%dT%H:%M:%SZ)
    old_iso=$(date -u -d "@$(( $(date +%s) - 2400 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-2400S +%Y-%m-%dT%H:%M:%SZ)
    computed_age=$(printf '%s\n%s\n' "$recent_iso" "$old_iso" | oldest_age_from_timestamps)
    # Must be close to 2400s (the OLDEST), not 120s (the newest, which a
    # naive "first element of a newest-first list" bug would return).
    oldest_ok=0
    [[ "$computed_age" -ge 2350 && "$computed_age" -le 2450 ]] && oldest_ok=1
    assert_true "$oldest_ok" "oldest_age_from_timestamps picks the OLDEST timestamp (got ${computed_age}s, want ~2400s, NOT ~120s)"

    echo "== scenario 9: empty host inventory is itself an alert condition =="
    empty_inv_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=""
    }
    empty_inv_tick; run_one_tick
    empty_inv_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[inventory:host]:-}" "alert" "empty inventory: alert fires at debounce (old bug: silently checked nothing and passed)"

    echo "== scenario 10: ghost runner (GitHub knows about it, host has no directory for it) =="
    ghost_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-ops\tpneuma-ops-contabo\t/home/ubuntu/actions-runner-pneuma-ops-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-ops.pneuma-ops-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-ops-contabo"]="1"
        FIXTURE_GH_STATUS["pneuma-ops/pneuma-ops-contabo"]="online"
        FIXTURE_GH_STATUS["pneuma-ops/pneuma-ops-contabo-orphan"]="offline"   # GitHub knows this one; host has no dir for it
    }
    ghost_tick; run_one_tick
    ghost_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[ghost:pneuma-ops:pneuma-ops-contabo-orphan]:-}" "alert" "ghost runner (registered on GitHub, no host dir): alert fires"
    assert_eq "${TICK_ACTIONS[runner:pneuma-ops:pneuma-ops-contabo]:-}" "" "the real, matched runner is unaffected"

    echo "== scenario 11: expired token / total API failure must exit non-zero so OnFailure= can fire =="
    all_fail_tick() {
        clear_fixtures
        local r
        for r in $REPOS; do
            FIXTURE_GH_REPO_FAIL["$r"]=1
            FIXTURE_QUEUE_FAIL["$r"]=1
        done
    }
    all_fail_tick; run_one_tick
    exit_ok=0
    [[ "$TICK_EXIT_CODE" -eq 2 ]] && exit_ok=1
    assert_true "$exit_ok" "every GitHub call failing this tick sets TICK_EXIT_CODE=2 (old bug: always exited 0, OnFailure= never fired)"

    echo
    if [[ "$failures" -eq 0 ]]; then
        echo "SELF-TEST PASSED — the wedge signature and every reviewed bug are covered."
    else
        echo "SELF-TEST FAILED: $failures assertion(s) failed."
    fi
    return "$failures"
}

if [[ "$MODE" == "self-test" ]]; then
    self_test
    exit $?
fi

load_state
run_one_tick
update_heartbeat
exit "$TICK_EXIT_CODE"
SCRIPT
sed -i "s|__ALERT_REPO__|$ALERT_REPO|; s|__DEBOUNCE_TICKS__|$DEBOUNCE_TICKS|; s|__QUEUED_ALERT_GRACE__|$QUEUED_ALERT_GRACE|" /usr/local/bin/runner-liveness-check
chmod 755 /usr/local/bin/runner-liveness-check

cat > /etc/systemd/system/runner-liveness-check.service <<'UNIT'
[Unit]
Description=Alert on wedged GitHub Actions runners (host-vs-GitHub liveness check)
OnFailure=runner-liveness-check-failure-alert.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/runner-liveness-check
UNIT

cat > /etc/systemd/system/runner-liveness-check.timer <<'UNIT'
[Unit]
Description=Run runner-liveness-check every 5 minutes

[Timer]
OnBootSec=7min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

# OnFailure unit: if the main check ever exits non-zero (a crash, a
# missing/expired token, or a tick where every GitHub call failed — the
# main script tolerates a PARTIAL failure on its own, it's only a TOTAL
# one that reaches here), file/update a GitHub issue saying the WATCHDOG
# ITSELF is not working. Deduplicated against any existing open issue of
# the same title (the original version created a new issue on every
# single failed tick); exits non-zero itself if it can't even do that,
# rather than swallowing the failure.
cat > /usr/local/bin/runner-liveness-check-failure-alert <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
TOKEN=$(cat /root/.runner-liveness-token 2>/dev/null) || { echo "no token file" >&2; exit 1; }
[[ -n "$TOKEN" ]] || { echo "empty token" >&2; exit 1; }
OWNER=deanmak13
ALERT_REPO="__ALERT_REPO__"
TITLE="[runner-liveness] the liveness checker itself failed to run"
BODY="runner-liveness-check.service failed on ci-builder — see 'journalctl -u runner-liveness-check' for the crash. The watchdog cannot currently detect wedged runners."

AUTH_HEADER_FILE=$(mktemp)
trap 'rm -f "$AUTH_HEADER_FILE"' EXIT
( umask 077; printf 'Authorization: Bearer %s\n' "$TOKEN" > "$AUTH_HEADER_FILE" )

existing=$(curl -sf -m 20 -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues?labels=runner-liveness&state=open&per_page=100" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
title = sys.argv[1]
for i in d:
    if i.get('title') == title:
        print(i['number']); break
" "$TITLE") || { echo "failed to list open issues" >&2; exit 1; }

if [[ -n "$existing" ]]; then
    curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing/comments" \
        -d "$(python3 -c "
import json, sys
print(json.dumps({'body': 'still failing: ' + sys.argv[1]}))
" "$BODY")" >/dev/null || { echo "failed to comment on issue #$existing" >&2; exit 1; }
else
    curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues" \
        -d "$(python3 -c "
import json, sys
print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['runner-liveness']}))
" "$TITLE" "$BODY")" >/dev/null || { echo "failed to create issue" >&2; exit 1; }
fi
SCRIPT
sed -i "s|__ALERT_REPO__|$ALERT_REPO|" /usr/local/bin/runner-liveness-check-failure-alert
chmod 755 /usr/local/bin/runner-liveness-check-failure-alert

cat > /etc/systemd/system/runner-liveness-check-failure-alert.service <<'UNIT'
[Unit]
Description=File a GitHub issue if runner-liveness-check.service itself fails

[Service]
Type=oneshot
ExecStart=/usr/local/bin/runner-liveness-check-failure-alert
UNIT

touch /var/log/runner-liveness-check.log
cat > /etc/logrotate.d/runner-liveness-check <<'ROT'
/var/log/runner-liveness-check.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
ROT

systemctl daemon-reload
systemctl enable --now runner-liveness-check.timer
log "installed and started runner-liveness-check.timer (debounce ${DEBOUNCE_TICKS} ticks, queued-alert-grace ${QUEUED_ALERT_GRACE}s, alerts to deanmak13/$ALERT_REPO)"
