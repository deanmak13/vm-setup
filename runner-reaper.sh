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
# installer copies it from --token-file. Two uses: reaping reads Actions
# runs/jobs on every runner repo, and the runner-liveness cross-watch
# WRITES issues (search, create, comment, close) in --alert-repo.
# Token (least privilege): a fine-grained personal access token scoped to
# owner deanmak13 with exactly:
#   - Metadata: read (implied by any repo grant);
#   - Actions: read and Administration: read on the 10 Pneuma repos
#     (pneuma, pneuma-engine, pneuma-portal, pneuma-deployments,
#     pneuma-helm-charts, pneuma-proto, pneuma-ops, pneuma-mem0,
#     pneuma-terraformer, pneuma-agent) — workflow runs/jobs, and the
#     self-hosted runner list (/actions/runners needs Administration);
#   - Issues: read and write on vm-setup (the alert repo) — searching,
#     filing, commenting on and closing alerts, and creating the
#     `runner-liveness` label the installers ensure;
#   - nothing else.
# (runner-liveness-check.sh copies this same token when given none, so
# one token meets both.) As installed on ci-builder (checked 2026-09-23)
# it is instead a classic OAuth token whose scopes include `repo` and far
# more (admin:org, delete_repo, ...): it works, but should be replaced by
# the token above. One that can't write issues makes every cross-watch
# alert a delivery failure — the run exits 1 and the OnFailure= unit
# reports it (see below).
#
# Usage:
#   sudo bash runner-reaper.sh --token-file /path/to/token [--grace-seconds 600] \
#       [--alert-repo vm-setup]
#
# The program itself is bin/runner-reaper (installed as
# /usr/local/bin/runner-reaper, tunables in /etc/default/runner-reaper);
# this installer only places files and units. It also accepts --dry-run: it
# runs the full evidence-gathering pipeline and logs what it WOULD do,
# without ever calling systemctl restart.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

[[ -n "$TOKEN_FILE" && -f "$TOKEN_FILE" ]] || err "--token-file is required and must exist"
[[ "$ALERT_REPO" =~ ^[A-Za-z0-9._-]+$ ]] || err "--alert-repo must be a bare repo name (no '/', no whitespace): $ALERT_REPO"
[[ "$GRACE" =~ ^[0-9]+$ ]] || err "--grace-seconds must be a non-negative integer: $GRACE"
[[ $EUID -eq 0 ]] || err "This script must be run as root (use sudo)"

# ── Host-only from here [host-only-begin] ────────────────────────────────

install -m 600 "$TOKEN_FILE" /root/.runner-reaper-token
log "token installed at /root/.runner-reaper-token"
# Every alert search filters on the runner-liveness label; without it each
# tick would file a duplicate. Ensure it exists before any timer starts.
install -m 755 "$REPO_DIR/bin/runner-alert-label" /usr/local/bin/runner-alert-label
/usr/local/bin/runner-alert-label /root/.runner-reaper-token "$ALERT_REPO" \
    || err "could not ensure the runner-liveness label in deanmak13/$ALERT_REPO (token needs Issues: write there)"

mkdir -p /var/lib/runner-reaper

install -m 755 "$REPO_DIR/bin/runner-reaper" /usr/local/bin/runner-reaper
install -m 755 "$REPO_DIR/bin/runner-failure-alert" /usr/local/bin/runner-failure-alert
install -m 644 "$REPO_DIR/systemd/runner-failure-alert@.service" /etc/systemd/system/runner-failure-alert@.service
printf 'GRACE=%s\nALERT_REPO=%s\n' "$GRACE" "$ALERT_REPO" > /etc/default/runner-reaper

# OnFailure unit: runner-reaper exits 1 when a cross-watch alert could not
# be delivered (round-3 review of vm-setup#9) or when it crashes;
# runner-failure-alert@runner-reaper then files/updates one deduplicated
# issue saying so (bin/runner-failure-alert). It uses the same token, so
# if the cause IS the token (revoked, lost issues scope) that fails too —
# it then exits non-zero itself and the failure is left visible in
# `systemctl --failed` / the journal rather than swallowed.
cat > /etc/systemd/system/runner-reaper.service <<'UNIT'
[Unit]
Description=Reap wedged GitHub Actions runner workers
OnFailure=runner-failure-alert@runner-reaper.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/runner-reaper
# The token header file lives in /tmp only for the run; a private /tmp
# means a SIGKILLed run (whose EXIT trap never fires) cannot leave it behind.
PrivateTmp=yes
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
# [host-only-end]
