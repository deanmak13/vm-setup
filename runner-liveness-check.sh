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

# Separate from the above: DETECTION can succeed completely (we know
# exactly who's dead) while DELIVERY still fails (the issue-search/
# create/comment/close calls to ALERT_REPO fail — wrong token scope,
# repo renamed, rate limited on writes specifically, etc). Round-3
# review finding 4: that used to exit 0 unconditionally — a due alert
# or the heartbeat got silently skipped, the state file still updated
# (so the reaper's mtime-staleness cross-watch sees nothing wrong
# either), and OnFailure= never fired. Reset once per live/dry-run
# process (NOT inside run_one_tick — update_heartbeat and
# close_watchdog_failure_issue_if_open run after it in the same tick
# and must accumulate into the same counter); self-test resets it at
# the top of run_one_tick instead, once per simulated tick, since
# those two functions are no-ops outside MODE=="live".
TICK_DELIVERY_FAILED=0

api() {
    curl -sf -m 20 -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" "$1"
}

# Wraps api() with the TICK_API_TOTAL/FAIL counters. Only used for the
# DETECTION reads (runner list, queued/in-progress run lists) — not for
# the alerting-side issue create/comment/close calls, which only happen
# after something is already confirmed dead and whose failure is handled
# on its own terms (see file_or_update_issue/resolve_issue).
#
# MUST be called as a plain statement — `api_call "$url"`, never
# `x=$(api_call "$url")` or `< <(api_call "$url")`. Round-2 review (N1)
# found the ORIGINAL version was only ever invoked via command/process
# substitution: bash forks a subshell to capture that output, so the
# TICK_API_TOTAL/TICK_API_FAIL increments below happened in a throwaway
# copy of the variables and never reached run_one_tick's shell — in live
# mode TICK_API_TOTAL silently stayed 0 forever, so the "every GitHub
# call failed this tick -> exit 2" check could never fire. The self-test
# fixture path masked this because its OWN counter increments (for the
# prefetch_github_runners self-test branch specifically) happen outside
# any subshell, so scenario 11 passed by coincidence while the real code
# path was completely broken (see scenario 12 below, which exercises the
# REAL live path with api() stubbed, and would have caught this).
#
# Sets API_CALL_OK (1/0) and API_CALL_BODY (the response body) instead
# of printing/returning a value, so nothing about this call can be
# captured into a subshell by a caller reaching for `$(...)`.
API_CALL_OK=0
API_CALL_BODY=""

api_call() {
    TICK_API_TOTAL=$((TICK_API_TOTAL + 1))
    if API_CALL_BODY=$(api "$1"); then
        API_CALL_OK=1
    else
        API_CALL_OK=0
        API_CALL_BODY=""
        TICK_API_FAIL=$((TICK_API_FAIL + 1))
    fi
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
        # api_call is a plain statement (see its own comment for why) —
        # its result is read back from API_CALL_OK/API_CALL_BODY, never
        # from a command-substituted return value.
        #
        # Paged (round-3 review finding 6): /actions/runners with no
        # per_page defaults to 30. Since "absent from the list" now
        # means "deregistered" (round-2 review N3), a repo with more
        # than 30 runners would false-alert on everything past the
        # first page. Bounded at 5 pages (500 runners) the same way
        # queue_state bounds its own pagination — nowhere near this
        # fleet's real size, just a sane ceiling.
        local rpage rn pfail=0
        for rpage in 1 2 3 4 5; do
            api_call "https://api.github.com/repos/$OWNER/$repo/actions/runners?per_page=100&page=$rpage"
            if [[ "$API_CALL_OK" != "1" ]]; then pfail=1; break; fi
            rn=0
            while IFS=$'\t' read -r name status; do
                [[ -n "$name" ]] || continue
                GH_RUNNER_STATUS["$repo/$name"]="$status"
                rn=$((rn + 1))
            done < <(printf '%s' "$API_CALL_BODY" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('runners') or []:
    print(f\"{r.get('name','')}\t{r.get('status') or 'unknown'}\")
" 2>/dev/null)
            [[ "$rn" -lt 100 ]] && break
        done
        if (( pfail )); then
            GH_REPO_OK[$repo]=0
            continue
        fi
        GH_REPO_OK[$repo]=1
    done
}

gh_runner_status_of() {
    # $1=repo $2=agentName -> online|offline|deregistered|unknown
    #   unknown       — this repo's runners-list fetch itself failed this
    #                   tick; no evidence either way.
    #   deregistered  — the fetch SUCCEEDED and GitHub's list simply does
    #                   not contain a runner by this name: definitively
    #                   not registered any more, not merely "can't tell"
    #                   (round-2 review N3 / mutation M7 — this used to
    #                   collapse into "unknown" and HOLD forever).
    [[ "${GH_REPO_OK[$1]:-0}" == "1" ]] || { echo "unknown"; return; }
    if [[ -z "${GH_RUNNER_STATUS[$1/$2]+set}" ]]; then
        echo "deregistered"
        return
    fi
    echo "${GH_RUNNER_STATUS[$1/$2]}"
}

# Globals set by queue_state() instead of printed output — see api_call's
# comment for why: queue_state is invoked from run_one_tick as a plain
# statement now (never `< <(queue_state ...)`), because that process
# substitution was ALSO a subshell that discarded api_call's counter
# updates one level further up the call stack (round-2 review N1).
QUEUE_AGE=-1       # -1 = confirmed empty queue (healthy); >=0 = OLDEST queued run's age
QUEUE_INPROG=-1    # informational only, never gates the decision; -1 = unknown
QUEUE_OK=0         # 1 = evidence usable this tick; 0 = unknown, caller must HOLD

queue_state() {
    # $1=repo. Sets QUEUE_AGE/QUEUE_INPROG/QUEUE_OK. MUST be called as a
    # plain statement (see above).
    QUEUE_AGE=-1; QUEUE_INPROG=-1; QUEUE_OK=0
    if [[ "$MODE" == "self-test" ]]; then
        if [[ "${FIXTURE_QUEUE_FAIL[$1]:-0}" == "1" ]]; then
            TICK_API_TOTAL=$((TICK_API_TOTAL + 1)); TICK_API_FAIL=$((TICK_API_FAIL + 1))
        else
            TICK_API_TOTAL=$((TICK_API_TOTAL + 1))
            QUEUE_AGE="${FIXTURE_QUEUED_AGE[$1]:--1}"
            QUEUE_INPROG="${FIXTURE_INPROGRESS[$1]:--1}"
            QUEUE_OK=1
        fi
        return
    fi
    local page times n all_times="" qfail=0
    for page in 1 2 3 4 5; do
        api_call "https://api.github.com/repos/$OWNER/$1/actions/runs?status=queued&per_page=100&page=$page"
        if [[ "$API_CALL_OK" != "1" ]]; then qfail=1; break; fi
        times=$(printf '%s' "$API_CALL_BODY" | python3 -c "
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
        return   # QUEUE_OK stays 0
    fi
    QUEUE_AGE=$(printf '%s' "$all_times" | oldest_age_from_timestamps) || QUEUE_AGE=-1
    api_call "https://api.github.com/repos/$OWNER/$1/actions/runs?status=in_progress&per_page=1"
    if [[ "$API_CALL_OK" == "1" ]]; then
        QUEUE_INPROG=$(printf '%s' "$API_CALL_BODY" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_count',-1))" 2>/dev/null) || QUEUE_INPROG=-1
    else
        QUEUE_INPROG=-1
    fi
    QUEUE_OK=1
}

# ============================================================
# Debounce + alerting state. STREAK/STATE/ISSUE_NUM/LAST_COMMENT hold "as
# of the start of this tick"; NEW_* accumulate "as of the end" and get
# copied over — the copy is what makes state self-pruning (a key not
# touched this tick just doesn't appear in NEW_* and is dropped).
# ============================================================

declare -A STREAK STATE ISSUE_NUM LAST_COMMENT HOLD_COUNT
declare -A NEW_STREAK NEW_STATE NEW_ISSUE NEW_LAST_COMMENT NEW_HOLD_COUNT TICK_ACTIONS TICK_COMMENTED

# How many consecutive HOLD ticks (no usable evidence) a key can survive
# before this check stops waiting and raises its own "cannot verify"
# alert instead. Round-2 review N2: an indefinite hold meant a single
# permanently-unreachable repo (renamed, token lost access, GitHub
# outage) was silently blind forever, AND a hung-but-running listener
# whose repo also can't be reached could never raise a NEW alert. ~6
# ticks at the default 5-minute cadence is ~30 minutes.
HOLD_THRESHOLD=6

load_state() {
    STREAK=(); STATE=(); ISSUE_NUM=(); LAST_COMMENT=(); HOLD_COUNT=()
    [[ ! -f "$STATE_FILE" ]] && return
    local key streak state issue lastc holdc
    while IFS=$'\t' read -r key streak state issue lastc holdc; do
        STREAK["$key"]="$streak"; STATE["$key"]="$state"
        ISSUE_NUM["$key"]="$issue"; LAST_COMMENT["$key"]="${lastc:-0}"
        HOLD_COUNT["$key"]="${holdc:-0}"
    done < "$STATE_FILE"
}

commit_tick() {
    STREAK=(); STATE=(); ISSUE_NUM=(); LAST_COMMENT=(); HOLD_COUNT=()
    local key
    for key in "${!NEW_STATE[@]}"; do
        STREAK["$key"]="${NEW_STREAK[$key]}"; STATE["$key"]="${NEW_STATE[$key]}"
        ISSUE_NUM["$key"]="${NEW_ISSUE[$key]:-0}"; LAST_COMMENT["$key"]="${NEW_LAST_COMMENT[$key]:-0}"
        HOLD_COUNT["$key"]="${NEW_HOLD_COUNT[$key]:-0}"
    done
    [[ "$MODE" == "live" ]] || return 0
    {
        for key in "${!STATE[@]}"; do
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "${STREAK[$key]}" "${STATE[$key]}" "${ISSUE_NUM[$key]:-0}" "${LAST_COMMENT[$key]:-0}" "${HOLD_COUNT[$key]:-0}"
        done
    } > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    return 0
}

# Carries a key's PREVIOUS tick values forward unchanged when this tick
# has no usable evidence for it (a GitHub call failed) — no streak
# movement, no action fired, and (critically) the key is NOT dropped by
# self-pruning: the debounce state and any open issue survive untouched
# until real evidence is available again.
#
# BUT this cannot go on forever (round-2 review N2): once a key has been
# held HOLD_THRESHOLD consecutive ticks with zero real evidence, holding
# any longer means "we genuinely cannot tell" becomes indistinguishable
# from "everything is fine", which is exactly backwards for a liveness
# check. At the threshold, file/update a "cannot verify" issue directly
# (bypassing the normal per-evaluate_key debounce — the hold streak
# already IS the debounce for this path) instead of holding again.
hold_key() {
    local key="$1" context_title="${2:-$1}" context_reason="${3:-no usable evidence for $1}"
    local cnt=$(( ${HOLD_COUNT[$key]:-0} + 1 ))
    if (( cnt >= HOLD_THRESHOLD )); then
        NEW_HOLD_COUNT["$key"]=0
        NEW_STATE["$key"]="dead"
        NEW_STREAK["$key"]=1
        NEW_ISSUE["$key"]="${ISSUE_NUM[$key]:-0}"
        NEW_LAST_COMMENT["$key"]="${LAST_COMMENT[$key]:-0}"
        # context_title is usually a caller's already-"[runner-liveness]
        # ..."-prefixed title (round-3 review finding 7 caught the result
        # double-prefixing to "[runner-liveness] cannot verify:
        # [runner-liveness] ..."). Strip a leading prefix before adding
        # our own, once.
        local bare_title="${context_title#"[runner-liveness] "}"
        file_or_update_issue "$key" "[runner-liveness] cannot verify: $bare_title" \
            "This check has had no usable evidence for '$key' for $cnt consecutive ticks: $context_reason. Treating this as failed rather than holding forever — check GitHub token scope/expiry and repo access/name for the repo(s) involved."
        return
    fi
    NEW_HOLD_COUNT["$key"]="$cnt"
    NEW_STATE["$key"]="${STATE[$key]:-healthy}"
    NEW_STREAK["$key"]="${STREAK[$key]:-0}"
    NEW_ISSUE["$key"]="${ISSUE_NUM[$key]:-0}"
    NEW_LAST_COMMENT["$key"]="${LAST_COMMENT[$key]:-0}"
}

# Globals set by gh_find_open_issue() instead of printed output — same
# subshell-loss reasoning as api_call (round-2 review N1 pattern) AND
# closes round-2 review N5: a caller can now tell "search failed" (skip
# filing, avoid a possible duplicate) apart from "search succeeded, no
# match" (safe to create).
FIND_ISSUE_OK=0
FIND_ISSUE_RESULT=""

gh_find_open_issue() {
    # $1=title (exact match). Sets FIND_ISSUE_OK (1/0) + FIND_ISSUE_RESULT.
    FIND_ISSUE_OK=0
    FIND_ISSUE_RESULT=""
    local body
    body=$(api "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues?labels=runner-liveness&state=open&per_page=100") || return
    # A 2xx whose body isn't the expected JSON list is a failed search
    # too, not "no match" — only a parsed list sets FIND_ISSUE_OK.
    local parsed
    parsed=$(printf '%s' "$body" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not isinstance(d, list):
    sys.exit(1)
title = sys.argv[1]
for i in d:
    if i.get('title') == title:
        print(i['number']); break
" "$1" 2>/dev/null) || return
    FIND_ISSUE_OK=1
    FIND_ISSUE_RESULT="$parsed"
}

file_or_update_issue() {
    # $1=key $2=title $3=body
    # NOTE: bash expands an ENTIRE `local a=X b=$a` command's right-hand
    # sides before any assignment in it takes effect, so `$key` used
    # within the SAME `local` statement that declares it would read a
    # stale/unset outer-scope `key`, not this function's own $1 — hence
    # `key`/`title`/`body` are declared first, `existing` on its own
    # following line. Found as a real (independent of round-2 review)
    # crash: `resolve_issue` had the identical bug and hit "key: unbound
    # variable" under `set -u` when called from a caller with no local
    # variable coincidentally also named `key` already in scope.
    local key="$1" title="$2" body="$3"
    local existing="${ISSUE_NUM[$key]:-0}"
    TICK_ACTIONS["$key"]="alert"
    local now_epoch; now_epoch=$(date +%s)
    if [[ "$MODE" == "self-test" ]]; then
        # Self-test applies the SAME hour-throttle as live/dry-run (round-2
        # review M5 test coverage) instead of always claiming a comment —
        # TICK_COMMENTED[$key] is only set when a comment/create would
        # actually have been attempted.
        local last="${LAST_COMMENT[$key]:-0}"
        if [[ "$existing" == "0" ]] || (( now_epoch - last >= COMMENT_THROTTLE_SECONDS )); then
            note "would file/update issue: $title"
            TICK_COMMENTED["$key"]=1
            NEW_LAST_COMMENT["$key"]="$now_epoch"
        else
            note "issue already open, comment throttled (self-test): $title"
            NEW_LAST_COMMENT["$key"]="$last"
        fi
        NEW_ISSUE["$key"]=1
        return
    fi
    if [[ "$MODE" == "dry-run" ]]; then
        note "DRY-RUN would file/update issue: $title :: $body"
        NEW_ISSUE["$key"]="$existing"
        NEW_LAST_COMMENT["$key"]="${LAST_COMMENT[$key]:-0}"
        return
    fi
    if [[ "$existing" == "0" ]]; then
        gh_find_open_issue "$title"
        if [[ "$FIND_ISSUE_OK" != "1" ]]; then
            # Round-2 review N5: a failed search used to fall through to
            # "no existing issue" and create a duplicate. Skip filing
            # entirely this tick instead — the next tick (this key's
            # streak already satisfied DEBOUNCE_TICKS, so evaluate_key
            # will call this again) gets another chance.
            note "skip filing/updating '$title': open-issue search failed this tick (avoiding a possible duplicate)"
            TICK_DELIVERY_FAILED=$((TICK_DELIVERY_FAILED + 1))
            NEW_ISSUE["$key"]=0
            NEW_LAST_COMMENT["$key"]="${LAST_COMMENT[$key]:-0}"
            return
        fi
        existing="$FIND_ISSUE_RESULT"
        [[ -n "$existing" ]] || existing=0
    fi
    if [[ "$existing" != "0" ]]; then
        # Comment on state re-confirmation, but at most once per hour —
        # a 5-minute tick cadence would otherwise post ~288 comments/day
        # on an issue that's just still open.
        local last="${LAST_COMMENT[$key]:-0}"
        if (( now_epoch - last >= COMMENT_THROTTLE_SECONDS )); then
            TICK_COMMENTED["$key"]=1
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
                TICK_DELIVERY_FAILED=$((TICK_DELIVERY_FAILED + 1))
                NEW_LAST_COMMENT["$key"]="$last"
            fi
        else
            note "issue #$existing already open, comment throttled ($(( now_epoch - last ))s since last, threshold ${COMMENT_THROTTLE_SECONDS}s): $title"
            NEW_LAST_COMMENT["$key"]="$last"
        fi
        NEW_ISSUE["$key"]="$existing"
    else
        TICK_COMMENTED["$key"]=1
        local resp num rc
        resp=$(curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues" \
            -d "$(python3 -c "
import json, sys
print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['runner-liveness']}))
" "$title" "$body")"); rc=$?
        if [[ "$rc" -eq 0 && -n "$resp" ]]; then
            num=$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',0))" 2>/dev/null) || num=0
            NEW_ISSUE["$key"]="$num"
            NEW_LAST_COMMENT["$key"]="$now_epoch"
            note "filed issue #$num: $title"
        else
            NEW_ISSUE["$key"]=0
            NEW_LAST_COMMENT["$key"]=0
            note "FAILED to file issue: $title"
            TICK_DELIVERY_FAILED=$((TICK_DELIVERY_FAILED + 1))
        fi
    fi
}

resolve_issue() {
    # $1=key $2=title (see file_or_update_issue's NOTE on why $existing
    # is a separate `local` statement, not appended to the first one)
    local key="$1" title="$2"
    local existing="${ISSUE_NUM[$key]:-0}"
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
            TICK_DELIVERY_FAILED=$((TICK_DELIVERY_FAILED + 1))
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
    NEW_HOLD_COUNT["$key"]=0   # real evidence this tick — reset the chronic-unknown counter

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
    NEW_STATE=(); NEW_STREAK=(); NEW_ISSUE=(); NEW_LAST_COMMENT=(); NEW_HOLD_COUNT=()
    TICK_ACTIONS=(); TICK_COMMENTED=()
    TICK_API_TOTAL=0; TICK_API_FAIL=0
    # Reset here (not just once in the top-level dispatch) so --self-test,
    # which calls run_one_tick many times in one process without ever
    # going through that dispatch, gets a clean per-simulated-tick count;
    # the live dispatch's own pre-load_state reset is redundant with this
    # but harmless (nothing runs between the two).
    TICK_DELIVERY_FAILED=0

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
        elif [[ "$gh_status" == "deregistered" ]]; then
            # The repo's runners-list fetch SUCCEEDED and simply does not
            # contain this runner name — definitively not registered any
            # more, not merely "can't tell". Round-2 review N3/mutation
            # M7: this used to collapse into "unknown" and HOLD forever
            # even though the fetch was a clean success.
            is_dead=1
            evidence="unit=active github_status=deregistered (GitHub's runner list no longer contains this name)"
        else
            # gh_status == unknown (this repo's fetch call itself failed:
            # token expired, rate limited, outage, 404/renamed repo).
            # Do NOT assume healthy. Fall back to the host-only signal —
            # unit active with no listener process is dead regardless of
            # whether GitHub could be asked. Otherwise there's no
            # evidence either way this tick: HOLD (see hold_key — round-2
            # review N2 makes this time-limited, not indefinite).
            if listener_alive "$dir"; then
                [[ "$MODE" == "dry-run" ]] && note "classify $key: HOLD (github status unknown, listener present, unit active)"
                hold_key "$key" "$title" "GitHub could not be asked about '$repo/$agent' (repo fetch failed) and the listener process is present, so the host alone cannot confirm dead or alive."
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

    # --- ghost keys whose repo's fetch FAILED this tick have no evidence
    # either way this run — hold them explicitly (round-2 review N4).
    # Without this, the end-of-tick prune below would silently drop (and
    # orphan the open issue for) a real ghost runner just because ITS
    # repo's fetch happened to fail once.
    local prev_ghost_key
    for prev_ghost_key in "${!STATE[@]}"; do
        case "$prev_ghost_key" in ghost:*) : ;; *) continue ;; esac
        [[ -n "${NEW_STATE[$prev_ghost_key]:-}" ]] && continue   # already handled above (still a live ghost this tick)
        local pgrepo="${prev_ghost_key#ghost:}"; pgrepo="${pgrepo%%:*}"
        [[ "${GH_REPO_OK[$pgrepo]:-0}" == "1" ]] && continue   # fetch succeeded — its absence is trustworthy; let the vanished-key pass below resolve it
        [[ "$MODE" == "dry-run" ]] && note "classify $prev_ghost_key: HOLD (its repo's fetch failed this tick)"
        hold_key "$prev_ghost_key" "$prev_ghost_key" "the repo's runners-list fetch failed this tick, so this ghost runner's continued existence can't be confirmed either way"
    done

    # --- per-repo queue starvation: OLDEST queued run's age; in_progress
    # is informational only (a single busy runner on a multi-runner repo
    # must not mask a stale queued job sitting behind it). queue_state is
    # called as a plain statement (never $(...) / < <(...) — see its own
    # comment / round-2 review N1) and read back via QUEUE_AGE/QUEUE_
    # INPROG/QUEUE_OK. ---
    local repo2 key2 title2 body2 is_dead2
    for repo2 in $REPOS; do
        queue_state "$repo2"
        key2="queue:$repo2"
        title2="[runner-liveness] $repo2: queued job with no runner picking it up"
        if [[ "$QUEUE_OK" != "1" ]]; then
            [[ "$MODE" == "dry-run" ]] && note "classify $key2: HOLD (queue API unknown this tick)"
            hold_key "$key2" "$title2" "the queued/in-progress-runs API call(s) for $repo2 failed this tick"
            continue
        fi
        if [[ "$QUEUE_AGE" == "-1" ]]; then
            is_dead2=0   # confirmed empty queue
        else
            is_dead2=0
            [[ "$QUEUE_AGE" -ge "$QUEUED_ALERT_GRACE" ]] && is_dead2=1
        fi
        body2="Repo $repo2: OLDEST queued run is ${QUEUE_AGE}s old (in_progress_runs=$QUEUE_INPROG, informational only — not required to be zero). "
        body2+="Alert threshold ${QUEUED_ALERT_GRACE}s. Check: gh run list --repo $OWNER/$repo2 --status queued. "
        body2+="If this repo has zero registered runners on ci-builder, register one (reference_contabo_ci_runner_setup)."
        [[ "$MODE" == "dry-run" ]] && note "classify $key2: is_dead=$is_dead2 queued_age=${QUEUE_AGE}s in_progress=$QUEUE_INPROG"
        evaluate_key "$key2" "$is_dead2" "$title2" "$body2"
    done

    # --- close out anything that legitimately vanished this tick and
    # still has an open issue, instead of silently orphaning it via
    # self-pruning (round-2 review N4). Only for keys whose disappearance
    # is TRUSTWORTHY evidence of "really gone", not "we failed to check":
    #   - runner:<repo>:<agent> — host_inventory() is a direct disk read
    #     that never "fails" the way a network call does, so a runner
    #     key's absence here is always trustworthy.
    #   - ghost:<repo>:<name>   — only trustworthy if that repo's fetch
    #     succeeded this tick (a failed fetch was already re-held above).
    #   - queue:<repo> / inventory:host are evaluated unconditionally
    #     every tick (evaluate_key or hold_key, never silently skipped),
    #     so they can never reach this path — the case/skip below is
    #     purely defensive.
    local prev_key
    for prev_key in "${!ISSUE_NUM[@]}"; do
        [[ -n "${NEW_STATE[$prev_key]:-}" ]] && continue          # already handled this tick
        [[ "${ISSUE_NUM[$prev_key]:-0}" == "0" ]] && continue     # nothing open to close
        case "$prev_key" in
            ghost:*)
                local vgrepo="${prev_key#ghost:}"; vgrepo="${vgrepo%%:*}"
                [[ "${GH_REPO_OK[$vgrepo]:-0}" == "1" ]] || continue
                ;;
            runner:*) : ;;
            *) continue ;;
        esac
        note "auto-resolving vanished key $prev_key (not present this tick; positively confirmed gone, not just unchecked)"
        resolve_issue "$prev_key" "[runner-liveness] $prev_key (vanished)"
        NEW_STATE["$prev_key"]="healthy"
        NEW_STREAK["$prev_key"]=0
        NEW_HOLD_COUNT["$prev_key"]=0
        NEW_LAST_COMMENT["$prev_key"]="${NEW_LAST_COMMENT[$prev_key]:-0}"
    done

    commit_tick

    TICK_EXIT_CODE=0
    if [[ "$TICK_API_TOTAL" -gt 0 && "$TICK_API_TOTAL" -eq "$TICK_API_FAIL" ]]; then
        TICK_EXIT_CODE=2
    fi
    # Round-3 review finding 4: also computed here (not only in the
    # top-level live dispatch) so --self-test, which never reaches that
    # dispatch, can assert on it per simulated tick.
    if [[ "$TICK_EXIT_CODE" -eq 0 && "$TICK_DELIVERY_FAILED" -gt 0 ]]; then
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
    gh_find_open_issue "$title"
    if [[ "$FIND_ISSUE_OK" != "1" ]]; then
        # Round-2 review N5: don't create a duplicate heartbeat issue
        # just because the search itself failed transiently. Round-3
        # review finding 4: this is a DELIVERY failure too — count it so
        # a chronically-failing ALERT_REPO can't hide behind a detection
        # tick that otherwise looked perfectly healthy.
        note "skip heartbeat: open-issue search failed this tick"
        TICK_DELIVERY_FAILED=$((TICK_DELIVERY_FAILED + 1))
        return
    fi
    local existing="$FIND_ISSUE_RESULT"
    local body
    body="Last liveness-check tick: $(date -Is). If this stops moving, the runner-liveness-check.timer itself may have stopped — check \`systemctl status runner-liveness-check.timer\` on ci-builder."
    if [[ -n "$existing" ]]; then
        curl -sf -m 20 -X PATCH -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing" \
            -d "$(python3 -c "import json,sys; print(json.dumps({'body': sys.argv[1]}))" "$body")" >/dev/null 2>&1 \
            || { note "FAILED to update heartbeat issue #$existing"; TICK_DELIVERY_FAILED=$((TICK_DELIVERY_FAILED + 1)); }
    else
        curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues" \
            -d "$(python3 -c "
import json, sys
print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['runner-liveness']}))
" "$title" "$body")" >/dev/null 2>&1 \
            || { note "FAILED to create heartbeat issue"; TICK_DELIVERY_FAILED=$((TICK_DELIVERY_FAILED + 1)); }
    fi
}

# Round-2 review minor fix: the OnFailure= meta-alert ("the liveness
# checker itself failed to run") never closed itself. Round-3 review
# finding 7: the first version closed it on the very FIRST healthy tick
# after a failure, so a flapping checker (fail, recover, fail, recover)
# would create-then-close-then-recreate the same issue every cycle.
# Debounced the same way every other alert is: DEBOUNCE_TICKS
# consecutive ticks that reached this point without a TICK_EXIT_CODE
# escalation, tracked in its own small persisted counter (separate from
# the main STREAK table — this isn't a per-key detection result, it's
# "is the checker itself currently trustworthy").
close_watchdog_failure_issue_if_open() {
    [[ "$MODE" == "live" ]] || return 0
    local streak_file="$STATE_DIR/watchdog-healthy-streak"
    local streak=0
    [[ -f "$streak_file" ]] && streak=$(cat "$streak_file" 2>/dev/null || echo 0)
    [[ "$streak" =~ ^[0-9]+$ ]] || streak=0
    if [[ "$TICK_EXIT_CODE" -ne 0 ]]; then
        echo 0 > "$streak_file" 2>/dev/null || true
        return 0
    fi
    streak=$((streak + 1))
    echo "$streak" > "$streak_file" 2>/dev/null || true
    [[ "$streak" -ge "$DEBOUNCE_TICKS" ]] || return 0

    local title="[runner-liveness] the liveness checker itself failed to run"
    gh_find_open_issue "$title"
    [[ "$FIND_ISSUE_OK" == "1" ]] || return 0
    local existing="$FIND_ISSUE_RESULT"
    [[ -n "$existing" ]] || return 0
    curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing/comments" \
        -d '{"body":"resolved: the checker is running again."}' >/dev/null 2>&1
    curl -sf -m 20 -X PATCH -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing" \
        -d '{"state":"closed"}' >/dev/null 2>&1 \
        && note "closed self-failure issue #$existing (checker healthy for $streak consecutive ticks)" \
        || note "FAILED to close self-failure issue #$existing"
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

    # ========================================================
    # Round-2 review (independent review of the fixes above). Each
    # scenario below exercises the REAL code path the fixture shortcut
    # was blind to, or a specific new failure mode the reviewer found.
    # ========================================================

    echo "== scenario 12 (N1): the REAL live code path (not the fixture shortcut) must count API failures and compute exit 2 =="
    # Two independent checks, deliberately NOT combined into one: a
    # regression that breaks ONLY prefetch_github_runners's counting (or
    # only queue_state's) must be caught on its own — the first version
    # of this test called both together, and queue_state's correct
    # counting alone was enough to pass the combined assertion, silently
    # masking a prefetch_github_runners-only regression. Never combine
    # coverage like that again.
    n1_prefetch_test() {
        MODE="live"
        api() { return 1; }
        TICK_API_TOTAL=0; TICK_API_FAIL=0
        GH_RUNNER_STATUS=(); GH_REPO_OK=()
        prefetch_github_runners
        echo "$TICK_API_TOTAL $TICK_API_FAIL"
    }
    n1_queue_test() {
        MODE="live"
        api() { return 1; }
        TICK_API_TOTAL=0; TICK_API_FAIL=0
        queue_state "pneuma"
        echo "$TICK_API_TOTAL $TICK_API_FAIL"
    }
    n1p_total=0; n1p_fail=0
    read -r n1p_total n1p_fail < <(n1_prefetch_test)
    n1p_attempted=0; [[ "$n1p_total" -gt 0 ]] && n1p_attempted=1
    assert_true "$n1p_attempted" "N1: prefetch_github_runners alone attempted API calls (TICK_API_TOTAL=$n1p_total; was silently stuck at 0 before the fix)"
    assert_eq "$n1p_total" "$n1p_fail" "N1: prefetch_github_runners alone counted every attempted call as failed"

    n1q_total=0; n1q_fail=0
    read -r n1q_total n1q_fail < <(n1_queue_test)
    n1q_attempted=0; [[ "$n1q_total" -gt 0 ]] && n1q_attempted=1
    assert_true "$n1q_attempted" "N1: queue_state alone attempted API calls (TICK_API_TOTAL=$n1q_total; was silently stuck at 0 before the fix)"
    assert_eq "$n1q_total" "$n1q_fail" "N1: queue_state alone counted every attempted call as failed"

    n1_full_tick_test() {
        MODE="live"
        api() { return 1; }
        TICK_API_TOTAL=0; TICK_API_FAIL=0
        GH_RUNNER_STATUS=(); GH_REPO_OK=()
        prefetch_github_runners
        local r
        for r in $REPOS; do queue_state "$r"; done
        local exit_code=0
        [[ "$TICK_API_TOTAL" -gt 0 && "$TICK_API_TOTAL" -eq "$TICK_API_FAIL" ]] && exit_code=2
        echo "$exit_code"
    }
    n1_exit=0
    read -r n1_exit < <(n1_full_tick_test)
    assert_eq "$n1_exit" "2" "N1: a full live tick with every GitHub call stubbed to fail computes exit code 2 (old bug: counters never left the subshell, exit stayed 0)"

    echo "== scenario 13 (M1b): the REAL ps/grep listener_alive() check, not the fixture shortcut =="
    m1b_listener_test() {
        MODE="live"
        ps() { printf '%s\n' "  1234 /home/ubuntu/actions-runner-pneuma-agent-contabo/bin.2.337.0/Runner.Listener run --startuptype service"; }
        local present=1 absent=1
        listener_alive "/home/ubuntu/actions-runner-pneuma-agent-contabo" && present=0
        listener_alive "/home/ubuntu/actions-runner-someone-else-contabo" && absent=0
        echo "$present $absent"
    }
    m1b_present=1; m1b_absent=1
    read -r m1b_present m1b_absent < <(m1b_listener_test)
    assert_eq "$m1b_present" "0" "M1b: real listener_alive() reports alive(0) for a dir with a matching Runner.Listener ps line"
    assert_eq "$m1b_absent" "1" "M1b: real listener_alive() reports absent(1) for a dir with no matching line"

    echo "== scenario 14 (N3 / mutation M7): runner deregistered from GitHub (fetch OK, name absent from list) must alert, not HOLD forever =="
    deregistered_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-terraformer\tpneuma-terraformer-contabo\t/home/ubuntu/actions-runner-pneuma-terraformer-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-terraformer.pneuma-terraformer-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-terraformer-contabo"]="1"
        # Deliberately no FIXTURE_GH_STATUS entry for this repo/name, and
        # no FIXTURE_GH_REPO_FAIL either: the repo's fetch succeeds, but
        # the name just isn't in the list -> gh_runner_status_of returns
        # "deregistered", not "unknown".
    }
    deregistered_tick; run_one_tick
    deregistered_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-terraformer:pneuma-terraformer-contabo]:-}" "alert" "M7/N3: deregistered runner (fetch OK, name absent from list) alerts instead of holding forever"

    echo "== scenario 15 (N2): sustained unknown status past the hold limit raises its own 'cannot verify' alert =="
    chronic_unknown_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-portal\tpneuma-portal-contabo\t/home/ubuntu/actions-runner-pneuma-portal-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-portal.pneuma-portal-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-portal-contabo"]="1"
        FIXTURE_GH_REPO_FAIL["pneuma-portal"]=1
    }
    for i in 1 2 3 4 5; do
        chronic_unknown_tick; run_one_tick
        assert_eq "${TICK_ACTIONS[runner:pneuma-portal:pneuma-portal-contabo]:-}" "" "N2: chronic-unknown tick $i (< hold threshold $HOLD_THRESHOLD): still just holding, no action"
    done
    chronic_unknown_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma-portal:pneuma-portal-contabo]:-}" "alert" "N2: chronic-unknown tick $HOLD_THRESHOLD (hold threshold reached): 'cannot verify' alert fires (old bug: held forever, silently blind)"

    echo "== scenario 16 (N4): a vanished key (runner dir removed from host) must close its open issue, not orphan it =="
    vanish_present_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma\tpneuma-contabo\t/home/ubuntu/actions-runner-pneuma-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma.pneuma-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-contabo"]="0"
        FIXTURE_GH_STATUS["pneuma/pneuma-contabo"]="offline"
    }
    vanish_present_tick; run_one_tick
    vanish_present_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma:pneuma-contabo]:-}" "alert" "N4 vanish scenario: alert opens first"
    vanish_gone_tick() {
        clear_fixtures
        # A DIFFERENT, unrelated healthy runner in this tick's inventory —
        # pneuma-contabo is intentionally absent, as if its directory was
        # removed from the host (not just an empty inventory overall,
        # which is a separate, already-covered condition).
        FIXTURE_INVENTORY=$'pneuma-proto\tpneuma-proto-contabo\t/home/ubuntu/actions-runner-pneuma-proto-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-proto.pneuma-proto-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-proto-contabo"]="1"
        FIXTURE_GH_STATUS["pneuma-proto/pneuma-proto-contabo"]="online"
    }
    vanish_gone_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[runner:pneuma:pneuma-contabo]:-}" "resolve" "N4: a runner disappearing from host inventory closes its open issue instead of orphaning it (old bug: silently pruned, issue number lost)"

    echo "== scenario 17 (M5): the comment throttle actually suppresses repeat comments within an hour =="
    throttle_wedged_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-mem0\tpneuma-mem0-contabo\t/home/ubuntu/actions-runner-pneuma-mem0-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-mem0.pneuma-mem0-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-mem0-contabo"]="0"
        FIXTURE_GH_STATUS["pneuma-mem0/pneuma-mem0-contabo"]="offline"
    }
    throttle_wedged_tick; run_one_tick
    throttle_wedged_tick; run_one_tick
    assert_eq "${TICK_COMMENTED[runner:pneuma-mem0:pneuma-mem0-contabo]:-}" "1" "M5 baseline: the first alert always comments/creates"
    throttle_wedged_tick; run_one_tick
    assert_eq "${TICK_COMMENTED[runner:pneuma-mem0:pneuma-mem0-contabo]:-}" "" "M5: an immediate re-tick while still dead does NOT re-comment (throttled) — old bug: commented every 5 minutes, ~288/day"
    LAST_COMMENT[runner:pneuma-mem0:pneuma-mem0-contabo]=$(( $(date +%s) - COMMENT_THROTTLE_SECONDS - 10 ))
    throttle_wedged_tick; run_one_tick
    assert_eq "${TICK_COMMENTED[runner:pneuma-mem0:pneuma-mem0-contabo]:-}" "1" "M5: after the throttle window elapses, it comments again"

    # ========================================================
    # Round-3 review (independent re-review of the round-2 fixes above).
    # Confirmed N1-N5/minor/bonus closed; found these specific test gaps
    # and one new live-path regression class (delivery failures exiting
    # 0). Scenarios below use STATE (not TICK_ACTIONS) assertions where
    # the bug is specifically about silent self-pruning — TICK_ACTIONS
    # can be equally empty in both the correct-hold and the buggy-drop
    # case, since neither calls evaluate_key/file_or_update_issue/
    # resolve_issue that tick; only the persisted STATE/ISSUE_NUM tables
    # tell the two apart.
    # ========================================================

    echo "== scenario 18 (N4 ghost-hold): a ghost runner's tracking must survive a tick where its repo's fetch fails =="
    ghost_hold_baseline_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-ops\tpneuma-ops-contabo\t/home/ubuntu/actions-runner-pneuma-ops-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-ops.pneuma-ops-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-ops-contabo"]="1"
        FIXTURE_GH_STATUS["pneuma-ops/pneuma-ops-contabo"]="online"
        FIXTURE_GH_STATUS["pneuma-ops/pneuma-ops-contabo-ghost2"]="offline"   # no matching host dir -> ghost
    }
    ghost_hold_baseline_tick; run_one_tick
    ghost_hold_baseline_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[ghost:pneuma-ops:pneuma-ops-contabo-ghost2]:-}" "alert" "N4 ghost-hold baseline: ghost alert opens"
    ghost_hold_fail_tick() {
        clear_fixtures
        FIXTURE_INVENTORY=$'pneuma-ops\tpneuma-ops-contabo\t/home/ubuntu/actions-runner-pneuma-ops-contabo'
        FIXTURE_UNIT_STATE["actions.runner.deanmak13-pneuma-ops.pneuma-ops-contabo.service"]="active"
        FIXTURE_LISTENER_ALIVE["/home/ubuntu/actions-runner-pneuma-ops-contabo"]="1"
        FIXTURE_GH_REPO_FAIL["pneuma-ops"]=1   # whole repo's fetch fails this tick
    }
    ghost_hold_fail_tick; run_one_tick
    assert_eq "${TICK_ACTIONS[ghost:pneuma-ops:pneuma-ops-contabo-ghost2]:-}" "" "N4 ghost-hold: no action during the failed-fetch tick"
    assert_eq "${STATE[ghost:pneuma-ops:pneuma-ops-contabo-ghost2]:-MISSING}" "dead" "N4 ghost-hold: key survives the failed-fetch tick (still tracked, not silently dropped)"
    assert_eq "${ISSUE_NUM[ghost:pneuma-ops:pneuma-ops-contabo-ghost2]:-0}" "1" "N4 ghost-hold: issue number preserved across the held tick (not orphaned into a future duplicate)"

    echo "== scenario 19 (N5/M8 + finding 4): a failed open-issue SEARCH on the REAL live path skips filing and counts as a delivery failure =="
    m8_search_fail_test() {
        MODE="live"
        LOG=/dev/null
        logger() { :; }
        api() {
            case "$1" in
                *"/issues?labels="*) return 1 ;;   # search itself fails
                *) echo '{"number":123}' ;;
            esac
        }
        # Every write goes through curl; stub it (never the network) and
        # record each call in a file — curl runs inside $(...), so a
        # counter variable would be lost with the subshell.
        local writes; writes=$(mktemp)
        curl() { echo "$*" >> "$writes"; echo '{"number":123}'; }
        ISSUE_NUM=(); STATE=(); STREAK=(); LAST_COMMENT=(); HOLD_COUNT=()
        NEW_ISSUE=(); NEW_STATE=(); NEW_STREAK=(); NEW_LAST_COMMENT=(); NEW_HOLD_COUNT=(); TICK_ACTIONS=()
        TICK_DELIVERY_FAILED=0
        file_or_update_issue "runner:m8:test" "[runner-liveness] m8 test" "body"
        local nwrites; nwrites=$(grep -c . "$writes" || true)
        rm -f "$writes"
        echo "${NEW_ISSUE[runner:m8:test]:-MISSING} $TICK_DELIVERY_FAILED $nwrites"
    }
    m8_issue="X"; m8_delivfail="X"; m8_writes="X"
    read -r m8_issue m8_delivfail m8_writes < <(m8_search_fail_test)
    assert_eq "$m8_writes" "0" "M8/N5 live path: a failed search makes NO create/comment call (old bug: POSTed a duplicate)"
    assert_eq "$m8_issue" "0" "M8/N5 live path: a failed search leaves NEW_ISSUE at 0"
    assert_true "$([[ "$m8_delivfail" -gt 0 ]] && echo 1 || echo 0)" "finding 4: a failed search increments TICK_DELIVERY_FAILED (TICK_DELIVERY_FAILED=$m8_delivfail)"

    echo "== scenario 20 (M6): FIND_ISSUE_OK must not stay stale-true from an earlier successful search =="
    m6_stale_global_test() {
        MODE="live"
        # NOTE: redefine api() between calls rather than tracking a call
        # counter inside it — api() is always invoked via `$(api ...)`,
        # which forks a subshell, so a variable it mutates never
        # propagates back out (the exact class of bug N1 was about).
        # Redefining the function itself has no such problem.
        api() { echo '[]'; return 0; }
        gh_find_open_issue "[runner-liveness] m6 test"
        local first_ok="$FIND_ISSUE_OK"
        api() { return 1; }
        gh_find_open_issue "[runner-liveness] m6 test"
        local second_ok="$FIND_ISSUE_OK"
        echo "$first_ok $second_ok"
    }
    m6_first="X"; m6_second="X"
    read -r m6_first m6_second < <(m6_stale_global_test)
    assert_eq "$m6_first" "1" "M6: the first (successful) search sets FIND_ISSUE_OK=1"
    assert_eq "$m6_second" "0" "M6: a SUBSEQUENT failed search resets FIND_ISSUE_OK to 0 — not left stuck at the previous call's stale 1"

    echo "== scenario 21 (finding 7): the OnFailure self-failure issue's close is debounced, not fired on the first healthy tick =="
    watchdog_debounce_test() {
        MODE="live"
        LOG=/dev/null
        logger() { :; }
        STATE_DIR=$(mktemp -d)
        api() { echo '[{"number": 55, "title": "[runner-liveness] the liveness checker itself failed to run"}]'; }
        CLOSE_CALLS=0
        curl() {
            for a in "$@"; do
                [[ "$a" == *'"state":"closed"'* ]] && CLOSE_CALLS=$((CLOSE_CALLS + 1))
            done
            return 0
        }
        TICK_EXIT_CODE=0
        close_watchdog_failure_issue_if_open
        local after1="$CLOSE_CALLS"
        close_watchdog_failure_issue_if_open
        local after2="$CLOSE_CALLS"
        rm -rf "$STATE_DIR"
        echo "$after1 $after2"
    }
    wd_after1="X"; wd_after2="X"
    read -r wd_after1 wd_after2 < <(watchdog_debounce_test)
    assert_eq "$wd_after1" "0" "finding 7: first healthy tick after a failure does NOT close the self-failure issue yet (streak 1 < debounce $DEBOUNCE_TICKS)"
    assert_eq "$wd_after2" "1" "finding 7: second consecutive healthy tick closes it (streak reaches debounce)"

    echo "== scenario 22 (finding 6): runner-list pagination — more than one page of runners must all be seen =="
    m_pagination_test() {
        MODE="live"
        api() {
            # NOTE: match on "&page=N" (leading &), not "page=N" — the
            # URL also carries "per_page=100", which itself contains the
            # bare substring "page=1" ("per_PAGE=1" + "00"). Matching
            # without the "&" made every page number's request hit the
            # page-1 branch and masked this test entirely.
            case "$1" in
                *"&page=1"*) echo "{\"runners\":[$(python3 -c "print(','.join('{\"name\":\"r%d\",\"status\":\"online\"}' % i for i in range(100)))")]}" ;;
                *"&page=2"*) echo '{"runners":[{"name":"r100","status":"online"}]}' ;;
                *) echo '{"runners":[]}' ;;
            esac
        }
        TICK_API_TOTAL=0; TICK_API_FAIL=0
        GH_RUNNER_STATUS=(); GH_REPO_OK=()
        REPOS="pneuma"
        prefetch_github_runners
        echo "${#GH_RUNNER_STATUS[@]} ${GH_RUNNER_STATUS[pneuma/r100]:-MISSING}"
    }
    pg_count="X"; pg_r100="X"
    read -r pg_count pg_r100 < <(m_pagination_test)
    assert_eq "$pg_count" "101" "finding 6: prefetch sees all 101 runners across two pages (not just the first page's 100)"
    assert_eq "$pg_r100" "online" "finding 6: the runner on page 2 (r100) is present in GH_RUNNER_STATUS"

    echo "== scenario 23 (finding 7): a 'cannot verify' escalation title carries the [runner-liveness] prefix exactly once =="
    cv_title_test() {
        HOLD_COUNT=(); ISSUE_NUM=(); LAST_COMMENT=(); STATE=(); STREAK=()
        HOLD_COUNT["runner:cv:test"]=$((HOLD_THRESHOLD - 1))
        hold_key "runner:cv:test" "[runner-liveness] cv/test: wedged self-hosted runner" "test reason" \
            | sed -n 's/^  would file\/update issue: //p'
    }
    cv_title=$(cv_title_test)
    assert_eq "$cv_title" "[runner-liveness] cannot verify: cv/test: wedged self-hosted runner" "finding 7: escalation title is prefixed once, not '[runner-liveness] cannot verify: [runner-liveness] ...'"

    echo "== scenario 24 (finding 4): heartbeat and comment delivery failures on the REAL live path are counted =="
    hb_fail_test() {
        MODE="live"
        LOG=/dev/null
        logger() { :; }
        api() { echo '[{"number": 7, "title": "[runner-liveness] heartbeat"}, {"number": 8, "title": "[runner-liveness] hb/test: x"}]'; }
        curl() { return 22; }   # every write (PATCH/POST) fails
        TICK_DELIVERY_FAILED=0
        update_heartbeat
        local after_hb="$TICK_DELIVERY_FAILED"
        ISSUE_NUM=(); LAST_COMMENT=(); NEW_ISSUE=(); NEW_LAST_COMMENT=(); TICK_ACTIONS=()
        ISSUE_NUM["runner:hb:test"]=8; LAST_COMMENT["runner:hb:test"]=0
        file_or_update_issue "runner:hb:test" "[runner-liveness] hb/test: x" "body"
        echo "$after_hb $TICK_DELIVERY_FAILED"
    }
    hb_after="X"; hb_total="X"
    read -r hb_after hb_total < <(hb_fail_test)
    assert_eq "$hb_after" "1" "finding 4: a failed heartbeat PATCH counts as a delivery failure"
    assert_eq "$hb_total" "2" "finding 4: a failed comment on an open alert counts as a delivery failure"

    echo "== scenario 25 (finding 4): a 2xx search with a non-list body is a FAILED search, not 'no match' =="
    bad_body_test() {
        MODE="live"
        api() { echo '{"message": "Not Found"}'; }
        gh_find_open_issue "[runner-liveness] anything"
        echo "$FIND_ISSUE_OK"
    }
    assert_eq "$(bad_body_test)" "0" "finding 4: an error-object body leaves FIND_ISSUE_OK=0 (no duplicate filing)"

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

TICK_DELIVERY_FAILED=0
load_state
run_one_tick
update_heartbeat
# Round-3 review finding 4: detection succeeding is not enough — if a due
# alert (or the heartbeat) could not actually be DELIVERED this tick,
# that's a failure of the whole check's purpose even though TICK_EXIT_CODE
# from run_one_tick alone (which only reflects DETECTION evidence) may
# still be 0. Escalate, never de-escalate an already-2 exit code. Done
# BEFORE the watchdog-close step so a heartbeat delivery failure resets
# that step's healthy streak instead of counting toward closing the
# "checker failed" issue.
if [[ "$TICK_EXIT_CODE" -eq 0 && "$TICK_DELIVERY_FAILED" -gt 0 ]]; then
    TICK_EXIT_CODE=2
fi
close_watchdog_failure_issue_if_open
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
