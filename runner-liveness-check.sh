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
# The program itself is bin/runner-liveness-check (installed as
# /usr/local/bin/runner-liveness-check, tunables in
# /etc/default/runner-liveness-check); this installer only places files
# and units. The installed program also accepts:
#   --dry-run    real ps/systemctl/GitHub-API data, logs what it WOULD
#                file/close, never calls the issues-write endpoints.
#   --self-test  fixture data (zero ps/systemctl/network calls). Exits
#                non-zero on any assertion failure. This is the
#                recurrence-guard proof — run it any time to confirm the
#                detector still catches the incident shape (and every
#                bug found in review) it was built for, entirely offline.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

[[ "$ALERT_REPO" =~ ^[A-Za-z0-9._-]+$ ]] || err "--alert-repo must be a bare repo name (no '/', no whitespace): $ALERT_REPO"
[[ "$DEBOUNCE_TICKS" =~ ^[0-9]+$ && "$DEBOUNCE_TICKS" -ge 1 ]] || err "--debounce-ticks must be a positive integer: $DEBOUNCE_TICKS"
[[ "$QUEUED_ALERT_GRACE" =~ ^[0-9]+$ ]] || err "--queued-alert-grace-seconds must be a non-negative integer: $QUEUED_ALERT_GRACE"
[[ $EUID -eq 0 ]] || err "This script must be run as root (use sudo)"

# ── Host-only from here [host-only-begin] ────────────────────────────────

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

install -m 755 "$REPO_DIR/bin/runner-liveness-check" /usr/local/bin/runner-liveness-check
printf 'ALERT_REPO=%s\nDEBOUNCE_TICKS=%s\nQUEUED_ALERT_GRACE=%s\n' "$ALERT_REPO" "$DEBOUNCE_TICKS" "$QUEUED_ALERT_GRACE" \
    > /etc/default/runner-liveness-check

cat > /etc/systemd/system/runner-liveness-check.service <<'UNIT'
[Unit]
Description=Alert on wedged GitHub Actions runners (host-vs-GitHub liveness check)
OnFailure=runner-failure-alert@runner-liveness-check.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/runner-liveness-check
# The token header file lives in /tmp only for the run; a private /tmp
# means a SIGKILLed run (whose EXIT trap never fires) cannot leave it behind.
PrivateTmp=yes
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
install -m 755 "$REPO_DIR/bin/runner-failure-alert" /usr/local/bin/runner-failure-alert
install -m 644 "$REPO_DIR/systemd/runner-failure-alert@.service" /etc/systemd/system/runner-failure-alert@.service

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
# [host-only-end]
