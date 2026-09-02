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
# Requires: a GitHub token with repo read scope at /root/.runner-reaper-token
# (mode 600). The installer copies it from --token-file.
#
# Usage:
#   sudo bash runner-reaper.sh --token-file /path/to/token [--grace-seconds 600]
#
# The installed /usr/local/bin/runner-reaper also accepts --dry-run: it
# runs the full evidence-gathering pipeline and logs what it WOULD do,
# without ever calling systemctl restart.

set -euo pipefail

GRACE=600
TOKEN_FILE=""

log() { echo "[runner-reaper] $*"; }
err() { echo "[runner-reaper] ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token-file) TOKEN_FILE="$2"; shift 2 ;;
        --grace-seconds) GRACE="$2"; shift 2 ;;
        *) err "Unknown argument: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || err "This script must be run as root (use sudo)"
[[ -n "$TOKEN_FILE" && -f "$TOKEN_FILE" ]] || err "--token-file is required and must exist"

install -m 600 "$TOKEN_FILE" /root/.runner-reaper-token
log "token installed at /root/.runner-reaper-token"

mkdir -p /var/lib/runner-reaper

cat > /usr/local/bin/runner-reaper <<'SCRIPT'
#!/usr/bin/env bash
# Reap GitHub Actions Runner.Worker zombies. Installed by vm-setup/runner-reaper.sh.
# See the header comment in vm-setup/runner-reaper.sh for the full design rationale.
set -uo pipefail

GRACE=__GRACE__
TOKEN=$(cat /root/.runner-reaper-token)
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

note() { echo "$(date -Is) $*" >> "$LOG"; logger -t runner-reaper "$*"; }

# ---- job-level liveness: sets JOB_ALIVE_EVIDENCE, returns 0=alive 1=dead 2=API failure
job_level_alive() {
    local repo=$1
    local runs_json ids checked=0 alive_jobs=0 id jobs_json n
    runs_json=$(curl -sf -m 20 -H "Authorization: Bearer $TOKEN" \
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
        jobs_json=$(curl -sf -m 20 -H "Authorization: Bearer $TOKEN" \
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

# ---- persist state for next tick (self-prunes: only currently-seen pids/repos survive)
{
    for pid in "${!CUR_CPU[@]}"; do printf '%s\t%s\n' "$pid" "${CUR_CPU[$pid]}"; done
} > "$CPU_STATE_FILE.tmp" && mv "$CPU_STATE_FILE.tmp" "$CPU_STATE_FILE"

{
    for repo in "${!NEW_QUIET[@]}"; do printf '%s\t%s\n' "$repo" "${NEW_QUIET[$repo]}"; done
} > "$QUIET_STATE_FILE.tmp" && mv "$QUIET_STATE_FILE.tmp" "$QUIET_STATE_FILE"
SCRIPT
sed -i "s/__GRACE__/$GRACE/" /usr/local/bin/runner-reaper
chmod 755 /usr/local/bin/runner-reaper

cat > /etc/systemd/system/runner-reaper.service <<'UNIT'
[Unit]
Description=Reap wedged GitHub Actions runner workers

[Service]
Type=oneshot
ExecStart=/usr/local/bin/runner-reaper
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
log "installed and started runner-reaper.timer (grace ${GRACE}s)"
