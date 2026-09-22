#!/usr/bin/env bash
# runner-reaper.sh — Install a watchdog that reaps wedged GitHub Actions
# runner workers on the CI host.
#
# THE DISEASE (observed 2026-08-14, three separate times in one day):
# a Runner.Worker process survives its job — after a cancellation, an
# OOM kill of its child, or a lost connection — and keeps burning a full
# core while GitHub shows the runner "busy". Queued jobs then wait behind
# a phantom, and every OTHER repo's jobs on this 4-core host crawl. The
# portal admin gate was measured at 2-5h under this contention vs ~15min
# clean. Nothing reaps these workers; a human had to notice and restart
# runner services by hand.
#
# THE CURE (v3, 2026-08-19 — evidence that cannot lie): every 5 minutes,
# for each repo runner whose Runner.Worker process has existed longer
# than a grace period, gather TWO independent liveness signals before
# ever touching it:
#
#   1. JOB-level GitHub check. Run-level status ("queued"/"in_progress")
#      is provably unreliable: GitHub has been observed reporting a run
#      as "queued" while its job is actively executing under
#      commit-keyed concurrency (2026-08-19: killed two legitimate
#      5h-queued engine builds this way, at 22:15:54 and 00:10:38). So
#      we never trust run.status. Instead we take the newest 3
#      non-completed runs for the repo and ask the JOBS endpoint
#      directly — any job.status == "in_progress" means the repo is
#      alive, full stop.
#   2. Local CPU-progress check. Each tick we snapshot every Worker
#      PID's utime+stime from /proc; a worker whose CPU time grew by
#      more than 2s since the last tick is BUILDING and can never be
#      reaped, regardless of what the API says. A repo must show near-
#      zero CPU growth for TWO consecutive ticks (~10 minutes of real
#      idle) before it counts as CPU-dead.
#
# A repo is only reaped when BOTH signals agree it is dead: the jobs API
# shows nothing in-progress AND CPU has been flat for two ticks running.
# Either signal alone blocks reaping — this is deliberately biased
# toward leaving a wedged runner alone over killing a live build.
#
# Worker → repo derivation (v4, 2026-09-02): a Runner.Worker's argv[0] is
# /home/ubuntu/actions-runner-<runner-name>/bin[.<ver>]/Runner.Worker and
# the directory names the RUNNER, not the repo — pneuma-engine has four
# (…-contabo, -contabo-2, -contabo-build-1, -contabo-build-2). The repo is
# read from that runner's own .runner registration file (gitHubUrl); the
# earlier regex that stripped a -contabo[-N] suffix produced a repo GitHub
# has never heard of for every build-lane runner ("API check failed",
# skipped forever) and any process whose command line merely mentioned
# "actions-runner-" was scanned as a worker.
#
# Requires: a GitHub token at /root/.runner-reaper-token (mode 600); the
# installer copies it from --token-file. Two uses, two scopes:
#   - reaping reads Actions runs/jobs on every runner repo (repo read);
#   - the runner-liveness cross-watch below WRITES issues (search, create,
#     comment, close) in --alert-repo (default vm-setup).
# So the token needs issues WRITE on the alert repo, not just repo read:
# classic `repo` scope, or a fine-grained token with Actions:read on the
# runner repos plus Issues:read-and-write on the alert repo. Verified on
# ci-builder 2026-09-23: the installed token is a classic OAuth token
# whose scopes include `repo` (and considerably more than this needs), so
# it can write vm-setup issues today. A token that can't write issues
# makes every cross-watch alert a delivery failure — the run exits 1 and
# runner-reaper.service's OnFailure= unit reports it (see below).
#
# Usage:
#   sudo bash runner-reaper.sh --token-file /path/to/token [--grace-seconds 600] \
#       [--alert-repo vm-setup]
#
# The installed /usr/local/bin/runner-reaper also accepts --dry-run: it
# runs the full evidence-gathering pipeline and logs what it WOULD do,
# without ever calling systemctl restart.

set -euo pipefail

GRACE=600
TOKEN_FILE=""
ALERT_REPO="vm-setup"

log() { echo "[runner-reaper] $*"; }
err() { echo "[runner-reaper] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token-file) TOKEN_FILE="$2"; shift 2 ;;
        --grace-seconds) GRACE="$2"; shift 2 ;;
        --alert-repo) ALERT_REPO="$2"; shift 2 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || err "This script must be run as root (use sudo)"
[[ -n "$TOKEN_FILE" && -f "$TOKEN_FILE" ]] || err "--token-file is required and must exist"
[[ "$ALERT_REPO" =~ ^[A-Za-z0-9._-]+$ ]] || err "--alert-repo must be a bare repo name (no '/', no whitespace): $ALERT_REPO"
[[ "$GRACE" =~ ^[0-9]+$ ]] || err "--grace-seconds must be a non-negative integer: $GRACE"

install -m 600 "$TOKEN_FILE" /root/.runner-reaper-token
log "token installed at /root/.runner-reaper-token"

mkdir -p /var/lib/runner-reaper

cat > /usr/local/bin/runner-reaper <<'SCRIPT'
#!/usr/bin/env bash
# Reap GitHub Actions Runner.Worker zombies. Installed by vm-setup/runner-reaper.sh.
# See the header comment in vm-setup/runner-reaper.sh for the full design rationale.
set -uo pipefail

GRACE=__GRACE__
TOKEN_FILE_PATH=/root/.runner-reaper-token
OWNER=deanmak13
LOG=/var/log/runner-reaper.log
STATE_DIR=/var/lib/runner-reaper
CPU_STATE_FILE="$STATE_DIR/cpu-state.tsv"
QUIET_STATE_FILE="$STATE_DIR/quiet-streak.tsv"
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
CPU_ACTIVE_THRESHOLD_SEC=2
QUIET_TICKS_REQUIRED=2
# newest N non-completed runs to check at job level (>=3 per design)
JOB_CHECK_RUNS=3

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "$STATE_DIR"

# The token goes to curl through a mode-600 header file, never on its
# command line (visible to every local user in ps) and never in the log.
AUTH_HEADER_FILE=$(mktemp)
trap 'rm -f "$AUTH_HEADER_FILE"' EXIT
( umask 077; printf 'Authorization: Bearer %s\n' "$(cat "$TOKEN_FILE_PATH" 2>/dev/null)" > "$AUTH_HEADER_FILE" )

note() { echo "$(date -Is) $*" >> "$LOG"; logger -t runner-reaper "$*"; }

# ---- job-level liveness: sets JOB_ALIVE_EVIDENCE, returns 0=alive 1=dead 2=API failure
job_level_alive() {
    local repo=$1
    local runs_json ids checked=0 alive_jobs=0 id jobs_json n
    runs_json=$(curl -sf -m 20 -H @"$AUTH_HEADER_FILE" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$repo/actions/runs?per_page=10") || return 2
    ids=$(echo "$runs_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
runs=[r for r in (d.get('workflow_runs') or []) if r.get('status') != 'completed']
for r in runs[:$JOB_CHECK_RUNS]:
    print(r['id'])
") || return 2
    if [[ -z "$ids" ]]; then
        JOB_ALIVE_EVIDENCE="runs_checked=0 jobs_in_progress=0"
        return 1
    fi
    for id in $ids; do
        checked=$((checked+1))
        jobs_json=$(curl -sf -m 20 -H @"$AUTH_HEADER_FILE" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$OWNER/$repo/actions/runs/$id/jobs") || return 2
        n=$(echo "$jobs_json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
jobs=d.get('jobs') or []
print(sum(1 for j in jobs if j.get('status')=='in_progress'))
") || return 2
        alive_jobs=$((alive_jobs+n))
    done
    JOB_ALIVE_EVIDENCE="runs_checked=$checked jobs_in_progress=$alive_jobs"
    (( alive_jobs > 0 )) && return 0
    return 1
}

# ---- the runner install directory behind a Runner.Worker command line, or nothing
worker_dir() {
    [[ "$1" =~ ^(/[^[:space:]]*/actions-runner-[^/[:space:]]+)/bin[^/[:space:]]*/Runner\.Worker([[:space:]]|$) ]] || return 1
    echo "${BASH_REMATCH[1]}"
}

# ---- the repo a runner install directory is registered against (its .runner file)
worker_repo() {
    local url
    url=$(jq -r '.gitHubUrl // empty' "$1/.runner" 2>/dev/null) || return 1
    [[ "$url" == "https://github.com/$OWNER/"* ]] || return 1
    echo "${url##*/}"
}

# ---- load prior-tick state
declare -A PREV_CPU
if [[ -f "$CPU_STATE_FILE" ]]; then
    while read -r pid ticks; do PREV_CPU[$pid]=$ticks; done < "$CPU_STATE_FILE"
fi
declare -A PREV_QUIET
if [[ -f "$QUIET_STATE_FILE" ]]; then
    while read -r repo cnt; do PREV_QUIET[$repo]=$cnt; done < "$QUIET_STATE_FILE"
fi

# ---- scan current Worker processes: repo -> oldest age, repo -> pid list, pid -> cpu ticks now
declare -A OLDEST
declare -A WORKER_PIDS
declare -A CUR_CPU

while read -r pid etimes args; do
    dir=$(worker_dir "$args") || continue
    repo=$(worker_repo "$dir") || continue

    cur=${OLDEST[$repo]:-0}
    (( etimes > cur )) && OLDEST[$repo]=$etimes
    WORKER_PIDS[$repo]="${WORKER_PIDS[$repo]:-} $pid"

    stat_line=$(cat "/proc/$pid/stat" 2>/dev/null)
    if [[ -n "$stat_line" ]]; then
        # comm can contain spaces/parens; split after the LAST ') ' so the
        # remaining fields line up regardless of comm content.
        rest=${stat_line##*) }
        set -- $rest
        # rest field 1=state ... field 12=utime field 13=stime
        utime=${12:-0}; stime=${13:-0}
        CUR_CPU[$pid]=$(( utime + stime ))
    fi
done < <(ps -eo pid,etimes,args | grep '[R]unner.Worker' || true)

declare -A NEW_QUIET

for repo in "${!OLDEST[@]}"; do
    age=${OLDEST[$repo]}
    (( age < GRACE )) && continue

    # --- local CPU-progress signal for this repo's workers
    cpu_status="quiet"
    cpu_evidence=""
    for pid in ${WORKER_PIDS[$repo]}; do
        cur_ticks=${CUR_CPU[$pid]:-}
        if [[ -z "$cur_ticks" ]]; then
            cpu_status="unknown"; cpu_evidence="$cpu_evidence pid=$pid:no-stat"; continue
        fi
        prev_ticks=${PREV_CPU[$pid]:-}
        if [[ -z "$prev_ticks" ]]; then
            cpu_status="unknown"; cpu_evidence="$cpu_evidence pid=$pid:no-baseline"; continue
        fi
        delta_ticks=$(( cur_ticks - prev_ticks ))
        (( delta_ticks < 0 )) && delta_ticks=0
        delta_sec=$(( delta_ticks / CLK_TCK ))
        cpu_evidence="$cpu_evidence pid=$pid:cpu_delta=${delta_sec}s"
        (( delta_sec > CPU_ACTIVE_THRESHOLD_SEC )) && cpu_status="active"
    done

    if [[ "$cpu_status" == "quiet" ]]; then
        quiet_count=$(( ${PREV_QUIET[$repo]:-0} + 1 ))
    else
        quiet_count=0
    fi
    NEW_QUIET[$repo]=$quiet_count
    cpu_confirmed_dead=0
    (( quiet_count >= QUIET_TICKS_REQUIRED )) && cpu_confirmed_dead=1

    # --- job-level GitHub signal
    JOB_ALIVE_EVIDENCE=""
    job_level_alive "$repo"
    job_rc=$?

    evidence="age=${age}s cpu_status=$cpu_status quiet_streak=$quiet_count [$cpu_evidence ] job=[$JOB_ALIVE_EVIDENCE]"

    if (( job_rc == 2 )); then
        note "skip $repo: job API check failed ($evidence)"
        continue
    fi

    if (( job_rc == 0 )); then
        note "alive $repo: job in-progress — not reaping ($evidence)"
        continue
    fi

    if (( cpu_confirmed_dead == 0 )); then
        note "alive $repo: cpu not yet confirmed dead, need $QUIET_TICKS_REQUIRED consecutive quiet ticks — not reaping ($evidence)"
        continue
    fi

    units=$(systemctl list-units "actions.runner.$OWNER-$repo.*" --no-legend --plain | awk '{print $1}')
    if [[ -z "$units" ]]; then
        note "skip $repo: no matching systemd units ($evidence)"
        continue
    fi

    if (( DRY_RUN == 1 )); then
        note "DRY-RUN REAP $repo: would restart: $units ($evidence)"
    else
        note "REAP $repo: restarting: $units ($evidence)"
        systemctl restart $units
        NEW_QUIET[$repo]=0
    fi
done

# ---- cross-watch: alert if runner-liveness-check's own timer appears to
# have stopped firing (finding 11, round-2 review of vm-setup#9).
# runner-liveness-check watches for wedged RUNNERS; nothing was watching
# whether the WATCHER ITSELF is still running at all — its own
# `OnFailure=` unit only fires when a run actually happens and fails, not
# when the systemd timer that would trigger a run has been stopped,
# disabled, or uninstalled. reaper runs on its own separate timer with
# its own GitHub token, so it can notice this independently: if
# runner-liveness-check's state file hasn't been touched in over
# LIVENESS_STALE_SECONDS, something is wrong with ITS timer, and reaper
# files/updates (then, once fresh again, closes) a GitHub issue about it
# — the same alerting primitive runner-liveness-check itself uses, kept
# here as a few plain curl calls rather than a shared library, since
# reaper and runner-liveness-check are deliberately independent scripts
# (a bug in one must not blind the other).
#
# Round-3 review of vm-setup#9:
#   - a failed issue SEARCH is not "no open issue" (it used to POST a
#     duplicate every stale tick): search-failed skips filing and counts
#     as a delivery failure, the way the checker's gh_find_open_issue does;
#   - "still stale" comments are throttled to one per
#     LIVENESS_COMMENT_THROTTLE_SECONDS via a last-comment timestamp kept
#     in the reaper's own state dir (it used to comment every 5 minutes);
#   - any delivery failure (search, file, comment, close) makes the whole
#     run exit non-zero so runner-reaper.service fails and its OnFailure=
#     unit fires, instead of a "FAILED to file" line in an unwatched log;
#   - the alert repo comes from the installer's --alert-repo, not a
#     hardcoded name.
LIVENESS_STATE_FILE=/var/lib/runner-liveness/streak.tsv
LIVENESS_STALE_SECONDS=1200
LIVENESS_COMMENT_THROTTLE_SECONDS=3600
LIVENESS_ALERT_REPO="__ALERT_REPO__"
LIVENESS_ALERT_TITLE="[runner-liveness] the liveness checker's timer appears to have stopped"
LIVENESS_LAST_COMMENT_FILE="$STATE_DIR/liveness-alert-last-comment"
# Filed by runner-reaper-failure-alert.service (the OnFailure= unit below);
# closed here once DEBOUNCE_HEALTHY_RUNS consecutive runs delivered
# everything, so a flapping reaper doesn't create/close it every tick.
REAPER_FAILURE_TITLE="[runner-reaper] runner-reaper failed (crash or undelivered alert)"   # must match REAPER_FAILURE_TITLE in runner-reaper
REAPER_HEALTHY_STREAK_FILE="$STATE_DIR/healthy-streak"
DEBOUNCE_HEALTHY_RUNS=2
DELIVERY_FAILED=0

gh_api() {  # method url [json-body] — body on stdout, curl's exit status
    local method=$1 url=$2
    if [[ $# -ge 3 ]]; then
        curl -sf -m 20 -X "$method" -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" "$url" -d "$3"
    else
        curl -sf -m 20 -X "$method" -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" "$url"
    fi
}

# Sets LIVENESS_SEARCH_OK (1 = search succeeded), LIVENESS_EXISTING (the
# stale-timer issue's number; empty = confirmed none open) and
# REAPER_FAILURE_EXISTING (the OnFailure issue's number, for the
# debounced auto-close at the end). All are reset first so a failure can
# never be read as a stale earlier result.
find_liveness_issue() {
    LIVENESS_SEARCH_OK=0
    LIVENESS_EXISTING=""
    REAPER_FAILURE_EXISTING=""
    local body parsed
    body=$(gh_api GET "https://api.github.com/repos/$OWNER/$LIVENESS_ALERT_REPO/issues?labels=runner-liveness&state=open&per_page=100") || return 0
    parsed=$(printf '%s' "$body" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if not isinstance(d, list):
    sys.exit(1)
found={}
for i in d:
    t=i.get('title')
    if t in sys.argv[1:] and t not in found:
        found[t]=str(i['number'])
print('x'+found.get(sys.argv[1],'')+chr(9)+'x'+found.get(sys.argv[2],''))
" "$LIVENESS_ALERT_TITLE" "$REAPER_FAILURE_TITLE" 2>/dev/null) || return 0
    LIVENESS_SEARCH_OK=1
    IFS=$'\t' read -r LIVENESS_EXISTING REAPER_FAILURE_EXISTING <<< "$parsed"
    LIVENESS_EXISTING=${LIVENESS_EXISTING#x}
    REAPER_FAILURE_EXISTING=${REAPER_FAILURE_EXISTING#x}
}

delivery_failed() { note "$*"; DELIVERY_FAILED=$((DELIVERY_FAILED + 1)); }

if [[ -f "$LIVENESS_STATE_FILE" ]]; then
    liveness_age=$(( $(date +%s) - $(stat -c %Y "$LIVENESS_STATE_FILE" 2>/dev/null || echo 0) ))
else
    liveness_age=99999999   # no state file at all yet (e.g. never installed) counts as maximally stale
fi

now_epoch=$(date +%s)
last_comment=$(cat "$LIVENESS_LAST_COMMENT_FILE" 2>/dev/null || echo 0)
[[ "$last_comment" =~ ^[0-9]+$ ]] || last_comment=0

find_liveness_issue
if [[ "$LIVENESS_SEARCH_OK" != "1" ]]; then
    # Neither "file" nor "close" is safe without knowing what is open:
    # filing could duplicate, closing has no number. Retry next tick.
    if (( liveness_age > LIVENESS_STALE_SECONDS )); then
        delivery_failed "FAILED to search open issues in $OWNER/$LIVENESS_ALERT_REPO — cannot file/update liveness-timer-stale alert (state file ${liveness_age}s old)"
    else
        delivery_failed "FAILED to search open issues in $OWNER/$LIVENESS_ALERT_REPO — cannot check for a liveness-timer-stale issue to close"
    fi
elif (( liveness_age > LIVENESS_STALE_SECONDS )); then
    liveness_body="runner-reaper (a separate timer) found ${LIVENESS_STATE_FILE} unmodified for ${liveness_age}s, threshold ${LIVENESS_STALE_SECONDS}s. Check on ci-builder: systemctl status runner-liveness-check.timer ; journalctl -u runner-liveness-check.timer. The runner-wedge detector cannot currently be trusted."
    note "runner-liveness-check state file is ${liveness_age}s old (> ${LIVENESS_STALE_SECONDS}s) — its timer may have stopped"
    if (( DRY_RUN == 1 )); then
        note "DRY-RUN: would file/update liveness-timer-stale issue (age=${liveness_age}s)"
    elif [[ -n "$LIVENESS_EXISTING" ]]; then
        if (( now_epoch - last_comment < LIVENESS_COMMENT_THROTTLE_SECONDS )); then
            note "liveness-timer-stale issue #$LIVENESS_EXISTING already open, comment throttled (last $(( now_epoch - last_comment ))s ago)"
        elif gh_api POST "https://api.github.com/repos/$OWNER/$LIVENESS_ALERT_REPO/issues/$LIVENESS_EXISTING/comments" \
                "$(python3 -c "import json,sys; print(json.dumps({'body': 'still stale ('+sys.argv[1]+'s): '+sys.argv[2]}))" "$liveness_age" "$liveness_body")" >/dev/null; then
            echo "$now_epoch" > "$LIVENESS_LAST_COMMENT_FILE"
        else
            delivery_failed "FAILED to comment on liveness-timer-stale issue #$LIVENESS_EXISTING"
        fi
    elif gh_api POST "https://api.github.com/repos/$OWNER/$LIVENESS_ALERT_REPO/issues" \
            "$(python3 -c "
import json,sys
print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['runner-liveness']}))
" "$LIVENESS_ALERT_TITLE" "$liveness_body")" >/dev/null; then
        # Filing counts as the first notification: the next "still stale"
        # comment waits a full throttle window.
        echo "$now_epoch" > "$LIVENESS_LAST_COMMENT_FILE"
    else
        delivery_failed "FAILED to file liveness-timer-stale issue"
    fi
elif [[ -n "$LIVENESS_EXISTING" ]]; then
    if (( DRY_RUN == 1 )); then
        note "DRY-RUN: would close liveness-timer-stale issue #$LIVENESS_EXISTING (fresh again)"
    else
        note "runner-liveness-check state file is fresh again (${liveness_age}s) — closing issue #$LIVENESS_EXISTING"
        gh_api POST "https://api.github.com/repos/$OWNER/$LIVENESS_ALERT_REPO/issues/$LIVENESS_EXISTING/comments" \
            '{"body":"resolved: runner-liveness-check'"'"'s state file is fresh again."}' >/dev/null \
            || note "FAILED to post resolution comment on liveness-timer-stale issue #$LIVENESS_EXISTING (closing anyway)"
        if gh_api PATCH "https://api.github.com/repos/$OWNER/$LIVENESS_ALERT_REPO/issues/$LIVENESS_EXISTING" '{"state":"closed"}' >/dev/null; then
            rm -f "$LIVENESS_LAST_COMMENT_FILE"
        else
            delivery_failed "FAILED to close liveness-timer-stale issue #$LIVENESS_EXISTING"
        fi
    fi
fi

# ---- debounced auto-close of this reaper's own OnFailure issue
healthy_streak=$(cat "$REAPER_HEALTHY_STREAK_FILE" 2>/dev/null || echo 0)
[[ "$healthy_streak" =~ ^[0-9]+$ ]] || healthy_streak=0
if (( DELIVERY_FAILED > 0 )); then
    healthy_streak=0
else
    healthy_streak=$((healthy_streak + 1))
fi
echo "$healthy_streak" > "$REAPER_HEALTHY_STREAK_FILE"
if (( DELIVERY_FAILED == 0 && healthy_streak >= DEBOUNCE_HEALTHY_RUNS && DRY_RUN == 0 )) && [[ -n "$REAPER_FAILURE_EXISTING" ]]; then
    if gh_api PATCH "https://api.github.com/repos/$OWNER/$LIVENESS_ALERT_REPO/issues/$REAPER_FAILURE_EXISTING" '{"state":"closed"}' >/dev/null; then
        note "closed reaper self-failure issue #$REAPER_FAILURE_EXISTING (healthy for $healthy_streak consecutive runs)"
    else
        note "FAILED to close reaper self-failure issue #$REAPER_FAILURE_EXISTING — will retry next run"
    fi
fi

# ---- persist state for next tick (self-prunes: only currently-seen pids/repos survive)
{
    for pid in "${!CUR_CPU[@]}"; do printf '%s\t%s\n' "$pid" "${CUR_CPU[$pid]}"; done
} > "$CPU_STATE_FILE.tmp" && mv "$CPU_STATE_FILE.tmp" "$CPU_STATE_FILE"

{
    for repo in "${!NEW_QUIET[@]}"; do printf '%s\t%s\n' "$repo" "${NEW_QUIET[$repo]}"; done
} > "$QUIET_STATE_FILE.tmp" && mv "$QUIET_STATE_FILE.tmp" "$QUIET_STATE_FILE"

# State is persisted first (a delivery failure must not also lose the CPU
# baselines), then a delivery failure fails the unit so OnFailure= fires.
if (( DELIVERY_FAILED > 0 )); then
    note "exiting 1: $DELIVERY_FAILED GitHub alert delivery failure(s) this run"
    exit 1
fi
exit 0
SCRIPT
sed -i "s|__GRACE__|$GRACE|; s|__ALERT_REPO__|$ALERT_REPO|" /usr/local/bin/runner-reaper
chmod 755 /usr/local/bin/runner-reaper

cat > /etc/systemd/system/runner-reaper.service <<'UNIT'
[Unit]
Description=Reap wedged GitHub Actions runner workers
OnFailure=runner-reaper-failure-alert.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/runner-reaper
UNIT

# OnFailure unit: runner-reaper exits 1 when a cross-watch alert could not
# be delivered (round-3 review of vm-setup#9) or when it crashes. This
# files/updates one deduplicated issue saying so. It uses the same token,
# so if the cause IS the token (revoked, lost issues scope) this fails too
# — it then exits non-zero itself and the failure is left visible in
# `systemctl --failed` / the journal rather than swallowed.
cat > /usr/local/bin/runner-reaper-failure-alert <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
TOKEN=$(cat /root/.runner-reaper-token 2>/dev/null) || { echo "no token file" >&2; exit 1; }
[[ -n "$TOKEN" ]] || { echo "empty token" >&2; exit 1; }
OWNER=deanmak13
ALERT_REPO="__ALERT_REPO__"
TITLE="[runner-reaper] runner-reaper failed (crash or undelivered alert)"   # must match REAPER_FAILURE_TITLE in runner-reaper
BODY="runner-reaper.service failed on ci-builder — see 'journalctl -u runner-reaper' and /var/log/runner-reaper.log (look for FAILED lines). Its runner-liveness cross-watch alert may not have been delivered."

AUTH_HEADER_FILE=$(mktemp)
trap 'rm -f "$AUTH_HEADER_FILE"' EXIT
( umask 077; printf 'Authorization: Bearer %s\n' "$TOKEN" > "$AUTH_HEADER_FILE" )

existing=$(curl -sf -m 20 -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues?labels=runner-liveness&state=open&per_page=100" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
for i in d:
    if i.get('title') == sys.argv[1]:
        print(i['number']); break
" "$TITLE") || { echo "failed to list open issues" >&2; exit 1; }

if [[ -n "$existing" ]]; then
    curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues/$existing/comments" \
        -d "$(python3 -c "import json, sys; print(json.dumps({'body': 'still failing: ' + sys.argv[1]}))" "$BODY")" \
        >/dev/null || { echo "failed to comment on issue #$existing" >&2; exit 1; }
else
    curl -sf -m 20 -X POST -H @"$AUTH_HEADER_FILE" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$ALERT_REPO/issues" \
        -d "$(python3 -c "
import json, sys
print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['runner-liveness']}))
" "$TITLE" "$BODY")" >/dev/null || { echo "failed to create issue" >&2; exit 1; }
fi
SCRIPT
sed -i "s|__ALERT_REPO__|$ALERT_REPO|" /usr/local/bin/runner-reaper-failure-alert
chmod 755 /usr/local/bin/runner-reaper-failure-alert

cat > /etc/systemd/system/runner-reaper-failure-alert.service <<'UNIT'
[Unit]
Description=File a GitHub issue if runner-reaper.service itself fails

[Service]
Type=oneshot
ExecStart=/usr/local/bin/runner-reaper-failure-alert
UNIT

cat > /etc/systemd/system/runner-reaper.timer <<'UNIT'
[Unit]
Description=Run runner-reaper every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

touch /var/log/runner-reaper.log
cat > /etc/logrotate.d/runner-reaper <<'ROT'
/var/log/runner-reaper.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
ROT

systemctl daemon-reload
systemctl enable --now runner-reaper.timer
log "installed and started runner-reaper.timer (grace ${GRACE}s, alerts to deanmak13/$ALERT_REPO)"
