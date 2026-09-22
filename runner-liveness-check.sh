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
#   --self-test  fixture data (zero ps/systemctl/network calls), runs a
#                healthy scenario (asserts zero actions across 3 ticks)
#                and a reproduction of the 2026-09-08 wedge signature
#                (asserts an alert fires on the debounce tick, keeps
#                firing while still wedged, and a resolve fires once the
#                fixture recovers for DEBOUNCE_TICKS ticks). Exits
#                non-zero on any assertion failure. This is the
#                recurrence-guard proof — run it any time to confirm the
#                detector still catches the incident shape it was built
#                for, entirely offline.

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
TOKEN_FILE_PATH=/root/.runner-liveness-token
LOG=/var/log/runner-liveness-check.log
STATE_DIR=/var/lib/runner-liveness
STATE_FILE="$STATE_DIR/streak.tsv"
RUNNER_DIR_GLOB="/home/ubuntu/actions-runner-*"

# The fixed repo roster this checker watches for queued-job starvation —
# every self-hosted-runner-capable Pneuma repo, whether or not it
# currently has a runner registered on THIS host.
REPOS="pneuma pneuma-engine pneuma-portal pneuma-deployments pneuma-helm-charts pneuma-proto pneuma-ops pneuma-mem0 pneuma-terraformer pneuma-agent"

MODE="live"
[[ "${1:-}" == "--dry-run" ]] && MODE="dry-run"
[[ "${1:-}" == "--self-test" ]] && MODE="self-test"

TOKEN=""
[[ "$MODE" == "self-test" ]] || { mkdir -p "$STATE_DIR"; TOKEN=$(cat "$TOKEN_FILE_PATH"); }

note() {
    if [[ "$MODE" == "self-test" ]]; then echo "  $*"; return; fi
    if [[ "$MODE" == "dry-run" ]]; then echo "$*"; return; fi
    echo "$(date -Is) $*" >> "$LOG"
    logger -t runner-liveness-check "$*"
}

api() {
    curl -sf -m 20 -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" "$1"
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
declare -A FIXTURE_GH_STATUS       # "repo/name" -> online|offline
declare -A FIXTURE_QUEUED_AGE      # repo -> seconds
declare -A FIXTURE_INPROGRESS      # repo -> count
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

github_runner_status() {
    # $1=repo $2=agentName -> online|offline|unknown(api failure)
    if [[ "$MODE" == "self-test" ]]; then
        echo "${FIXTURE_GH_STATUS[$1/$2]:-unknown}"
        return
    fi
    local json
    json=$(api "https://api.github.com/repos/$OWNER/$1/actions/runners") || { echo "unknown"; return; }
    echo "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
name='$2'
for r in d.get('runners') or []:
    if r.get('name')==name:
        print(r.get('status') or 'unknown')
        break
else:
    print('unknown')
" 2>/dev/null || echo "unknown"
}

queue_state() {
    # $1=repo -> "queued_age_seconds<TAB>in_progress_count" (-1/-1 = no evidence this tick)
    if [[ "$MODE" == "self-test" ]]; then
        printf '%s\t%s\n' "${FIXTURE_QUEUED_AGE[$1]:--1}" "${FIXTURE_INPROGRESS[$1]:--1}"
        return
    fi
    local qjson ijson age inprog
    qjson=$(api "https://api.github.com/repos/$OWNER/$1/actions/runs?status=queued&per_page=1") || { printf '%s\t%s\n' -1 -1; return; }
    ijson=$(api "https://api.github.com/repos/$OWNER/$1/actions/runs?status=in_progress&per_page=1") || { printf '%s\t%s\n' -1 -1; return; }
    age=$(echo "$qjson" | python3 -c "
import json,sys,datetime
d=json.load(sys.stdin)
runs=d.get('workflow_runs') or []
if not runs: print(-1)
else:
    t=datetime.datetime.fromisoformat(runs[0]['created_at'].replace('Z','+00:00'))
    print(int((datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()))
" 2>/dev/null) || age=-1
    inprog=$(echo "$ijson" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_count',-1))" 2>/dev/null) || inprog=-1
    printf '%s\t%s\n' "$age" "$inprog"
}

# ============================================================
# Debounce + alerting state. STREAK/STATE/ISSUE_NUM hold "as of the start
# of this tick"; NEW_* accumulate "as of the end of this tick" and get
# copied over at the end of run_one_tick — the copy is what makes state
# self-pruning (a key not touched this tick just doesn't appear in NEW_*
# and is dropped).
# ============================================================

declare -A STREAK STATE ISSUE_NUM
declare -A NEW_STREAK NEW_STATE NEW_ISSUE TICK_ACTIONS

# Loaded ONCE per process (live/dry-run only) before the single tick that
# process performs. self-test never calls this — it starts from empty
# arrays and accumulates across simulated ticks entirely in-memory (see
# commit_tick below), since a self-test run is many ticks in one process.
load_state() {
    STREAK=(); STATE=(); ISSUE_NUM=()
    [[ ! -f "$STATE_FILE" ]] && return
    local key streak state issue
    while IFS=$'\t' read -r key streak state issue; do
        STREAK["$key"]="$streak"; STATE["$key"]="$state"; ISSUE_NUM["$key"]="$issue"
    done < "$STATE_FILE"
}

# Copies this tick's NEW_* results into STREAK/STATE/ISSUE_NUM so the
# NEXT tick (whether that's the next systemd-timer firing reading the
# file back in, or the next simulated self-test tick in the same
# process) sees the debounce streak advance. Self-pruning: a key not
# touched this tick is simply absent from NEW_* and drops out here.
commit_tick() {
    STREAK=(); STATE=(); ISSUE_NUM=()
    local key
    for key in "${!NEW_STATE[@]}"; do
        STREAK["$key"]="${NEW_STREAK[$key]}"; STATE["$key"]="${NEW_STATE[$key]}"; ISSUE_NUM["$key"]="${NEW_ISSUE[$key]:-0}"
    done
    [[ "$MODE" == "live" ]] || return 0
    {
        for key in "${!STATE[@]}"; do
            printf '%s\t%s\t%s\t%s\n' "$key" "${STREAK[$key]}" "${STATE[$key]}" "${ISSUE_NUM[$key]:-0}"
        done
    } > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    return 0
}

gh_find_open_issue() {
    # $1=title (exact match) -> issue number or empty
    api "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues?labels=runner-liveness&state=open&per_page=100" \
        | python3 -c "
import json,sys
d=json.load(sys.stdin)
title=sys.argv[1]
for i in d:
    if i.get('title')==title:
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
        return
    fi
    if [[ "$MODE" == "dry-run" ]]; then
        note "DRY-RUN would file/update issue: $title :: $body"
        NEW_ISSUE["$key"]="$existing"
        return
    fi
    if [[ "$existing" == "0" ]]; then
        existing=$(gh_find_open_issue "$title")
        [[ -n "$existing" ]] || existing=0
    fi
    if [[ "$existing" != "0" ]]; then
        curl -sf -m 20 -X POST -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing/comments" \
            -d "$(python3 -c "import json,sys; print(json.dumps({'body': 'still failing: ' + sys.argv[1]}))" "$body")" \
            >/dev/null 2>&1
        NEW_ISSUE["$key"]="$existing"
        note "updated issue #$existing: $title"
    else
        local resp num
        resp=$(curl -sf -m 20 -X POST -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues" \
            -d "$(python3 -c "
import json,sys
print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['runner-liveness']}))
" "$title" "$body")" 2>/dev/null) || resp=""
        num=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',0))" 2>/dev/null) || num=0
        NEW_ISSUE["$key"]="$num"
        note "filed issue #$num: $title"
    fi
}

resolve_issue() {
    # $1=key $2=title
    local key="$1" title="$2" existing="${ISSUE_NUM[$key]:-0}"
    TICK_ACTIONS["$key"]="resolve"
    if [[ "$MODE" == "self-test" ]]; then
        note "would resolve+close issue: $title"
        NEW_ISSUE["$key"]=0
        return
    fi
    if [[ "$MODE" == "dry-run" ]]; then
        note "DRY-RUN would resolve+close issue: $title"
        NEW_ISSUE["$key"]=0
        return
    fi
    if [[ "$existing" != "0" ]]; then
        curl -sf -m 20 -X POST -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing/comments" \
            -d '{"body":"resolved: liveness checks are healthy again."}' >/dev/null 2>&1
        curl -sf -m 20 -X PATCH -H "Authorization: Bearer $TOKEN" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing" \
            -d '{"state":"closed"}' >/dev/null 2>&1
        note "resolved+closed issue #$existing: $title"
    fi
    NEW_ISSUE["$key"]=0
}

# $1=key $2=is_dead(0/1) $3=title $4=body — advances the debounce streak
# and fires file_or_update_issue/resolve_issue only once the streak
# crosses DEBOUNCE_TICKS in either direction.
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

    local already_open="${ISSUE_NUM[$key]:-0}"
    if [[ "$cur_state" == "dead" && "$streak" -ge "$DEBOUNCE_TICKS" ]]; then
        file_or_update_issue "$key" "$title" "$body"
    elif [[ "$cur_state" == "healthy" && "$streak" -ge "$DEBOUNCE_TICKS" && "$already_open" != "0" ]]; then
        resolve_issue "$key" "$title"
    fi
}

# ============================================================
# One tick == everything a single systemd-timer firing does: scan the
# host inventory, cross-check GitHub, check every repo's queue, evaluate
# debounce, (in live mode) persist state.
# ============================================================

run_one_tick() {
    NEW_STATE=(); NEW_STREAK=(); NEW_ISSUE=(); TICK_ACTIONS=()

    local repo agent dir
    while IFS=$'\t' read -r repo agent dir; do
        [[ -n "${repo:-}" ]] || continue
        local unit_state_val gh_status key title body is_dead evidence listener_note
        unit_state_val=$(unit_state "$OWNER-$repo" "$agent")
        gh_status=$(github_runner_status "$repo" "$agent")
        key="runner:$repo:$agent"
        title="[runner-liveness] $repo/$agent: wedged self-hosted runner"

        if [[ "$unit_state_val" == "not-found" ]]; then
            is_dead=1
            evidence="unit=not-found github_status=$gh_status"
        elif [[ "$unit_state_val" == "active" && "$gh_status" == "offline" ]]; then
            if listener_alive "$dir"; then listener_note="present"; else listener_note="ABSENT"; fi
            is_dead=1
            evidence="unit=active listener=$listener_note github_status=offline"
        elif [[ "$unit_state_val" == "active" ]]; then
            is_dead=0
            evidence="unit=active github_status=$gh_status"
        elif [[ "$unit_state_val" == "unknown" || "$gh_status" == "unknown" ]]; then
            continue
        else
            is_dead=1
            evidence="unit=$unit_state_val github_status=$gh_status"
        fi

        body="Host unit $OWNER-$repo.$agent: $evidence. Runner install dir: $dir. "
        body+="Remediation: ssh ci-builder; check with systemctl status actions.runner.$OWNER-$repo.$agent.service; "
        body+="if the unit is active but GitHub still shows offline after a manual look, "
        body+="'systemctl restart actions.runner.$OWNER-$repo.$agent.service' is safe (listener re-registers "
        body+="and picks up queued work within seconds)."
        [[ "$MODE" == "dry-run" ]] && note "classify $key: is_dead=$is_dead $evidence"
        evaluate_key "$key" "$is_dead" "$title" "$body"
    done < <(host_inventory)

    local repo2 qage inprog key2 title2 body2 is_dead2
    for repo2 in $REPOS; do
        read -r qage inprog < <(queue_state "$repo2")
        key2="queue:$repo2"
        title2="[runner-liveness] $repo2: queued job with no runner picking it up"
        [[ "$qage" == "-1" || "$inprog" == "-1" ]] && continue
        is_dead2=0
        [[ "$inprog" -eq 0 && "$qage" -ge "$QUEUED_ALERT_GRACE" ]] && is_dead2=1
        body2="Repo $repo2: newest queued run is ${qage}s old, in_progress_runs=$inprog "
        body2+="(alert threshold ${QUEUED_ALERT_GRACE}s). Check: gh run list --repo $OWNER/$repo2 --status queued. "
        body2+="If this repo has zero registered runners on ci-builder, register one "
        body2+="(reference_contabo_ci_runner_setup)."
        [[ "$MODE" == "dry-run" ]] && note "classify $key2: is_dead=$is_dead2 queued_age=${qage}s in_progress=$inprog"
        evaluate_key "$key2" "$is_dead2" "$title2" "$body2"
    done

    commit_tick
}

# ============================================================
# --self-test: fixture scenarios reusing run_one_tick unmodified.
# ============================================================

self_test() {
    local failures=0

    clear_fixtures() {
        FIXTURE_UNIT_STATE=(); FIXTURE_LISTENER_ALIVE=(); FIXTURE_GH_STATUS=()
        FIXTURE_QUEUED_AGE=(); FIXTURE_INPROGRESS=(); FIXTURE_INVENTORY=""
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

    echo
    if [[ "$failures" -eq 0 ]]; then
        echo "SELF-TEST PASSED — the wedge signature is detected and resolved correctly."
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
SCRIPT
sed -i "s/__ALERT_REPO__/$ALERT_REPO/; s/__DEBOUNCE_TICKS__/$DEBOUNCE_TICKS/; s/__QUEUED_ALERT_GRACE__/$QUEUED_ALERT_GRACE/" /usr/local/bin/runner-liveness-check
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

# OnFailure unit: if the main check ever exits non-zero (a crash, not
# just a quiet API-failure tick — the main script tolerates those on its
# own), file a GitHub issue saying the WATCHDOG ITSELF failed. Closes the
# "nobody was watching the log that went quiet" gap for this script's own
# failure mode too.
cat > /usr/local/bin/runner-liveness-check-failure-alert <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
TOKEN=$(cat /root/.runner-liveness-token 2>/dev/null) || exit 0
OWNER=deanmak13
ALERT_REPO="__ALERT_REPO__"
curl -sf -m 20 -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues" \
    -d "$(python3 -c "
import json
print(json.dumps({
    'title': '[runner-liveness] the liveness checker itself failed to run',
    'body': 'runner-liveness-check.service failed on ci-builder — see journalctl -u runner-liveness-check for the crash. The watchdog cannot currently detect wedged runners.',
    'labels': ['runner-liveness'],
}))
")" >/dev/null 2>&1 || true
SCRIPT
sed -i "s/__ALERT_REPO__/$ALERT_REPO/" /usr/local/bin/runner-liveness-check-failure-alert
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
