#!/usr/bin/env bash
# ci-builder-gate-host.sh — the root-side provisioning of the remote gate on the build host.
# Run by ci-builder-gate.sh on the host (over ssh on stdin, or directly with --local-host):
#   bash ci-builder-gate-host.sh STAGE
# STAGE is the root-owned 0700 staging dir ci-builder-gate.sh made with mktemp; it holds
# pneuma-gate-runner and profiles/. Idempotent. Touches only the gate's own users, directories,
# profiles, runner and cron files; it never restarts k3s, the GitHub runner services or docker, and
# never touches a docker volume.
#
# Layout (who may write what):
#   /var/lib/pneuma-gate            root 0755
#     repos/       the object store, owned by `pneuma-gate`; units mount it read-only
#     envs/        the dependency-env cache, root-owned and frozen read-only; units mount it read-only
#     wheels/      staged proto wheels, root-owned; units mount them read-only
#     queue/       FIFO tickets of waiting runners (root)
#   /var/lib/pneuma-gate-state      root 0700: reservation markers and staged bundles (never visible to a unit)
# A gate itself runs as a transient service with DynamicUser=yes: a unique uid per run, so no run
# can read or write another's files, processes or sockets.
set -euo pipefail
STAGE="${1:?usage: ci-builder-gate-host.sh STAGE}"
case "$STAGE" in /var/lib/pneuma-gate-install/stage.??????) ;; *) echo "refusing: bad stage $STAGE" >&2; exit 1;; esac
# [host-only-begin]
id pneuma-gate >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pneuma-gate --shell /usr/sbin/nologin pneuma-gate
install -d -o root -g root -m 0755 /var/lib/pneuma-gate /var/lib/pneuma-gate/envs /var/lib/pneuma-gate/wheels /var/lib/pneuma-gate/queue
install -d -o pneuma-gate -g pneuma-gate -m 0755 /var/lib/pneuma-gate/repos
install -d -o root -g root -m 0700 /var/lib/pneuma-gate-state /var/lib/pneuma-gate-state/runs /var/lib/pneuma-gate-state/in
# The profiles run as root (the runner sources them as root): root owns everything, dirs 0755, files 0644,
# set in the root-owned staging copy BEFORE anything reaches the live path.
chown -R root:root "$STAGE/profiles"
find "$STAGE/profiles" -type d -exec chmod 0755 {} +
find "$STAGE/profiles" -type f -exec chmod 0644 {} +
install -d -o root -g root -m 0755 /usr/local/lib/pneuma-gate /usr/local/lib/pneuma-gate/profiles
cp -a "$STAGE/profiles/." /usr/local/lib/pneuma-gate/profiles/
find /usr/local/lib/pneuma-gate/profiles -mindepth 1 -maxdepth 1 -type f -name '*.sh' | while read -r f; do
  [ -e "$STAGE/profiles/$(basename "$f")" ] || rm -f -- "$f"   # a profile that is no longer shipped
done
# The runner: atomic replace, mktemp beside the target.
runner_tmp="$(mktemp /usr/local/bin/.pneuma-gate-runner.XXXXXX)"
install -o root -g root -m 0755 "$STAGE/pneuma-gate-runner" "$runner_tmp"
mv -f -- "$runner_tmp" /usr/local/bin/pneuma-gate-runner
# Janitor: the runner's own leftovers (queue tickets, markers, staged bundles, old keep-refs, stale
# loopback routes) — it deletes no run directory. Guard: stops gate units whose runner is gone and every
# gate unit when the disk is low. Both atomic; a dot-named temp file is ignored by cron.d while it exists.
cron_file() {  # <name> <schedule>
  local tmp; tmp="$(mktemp /etc/cron.d/.pneuma-gate-cron.XXXXXX)"
  printf '%s root /usr/local/bin/pneuma-gate-runner %s >/dev/null 2>&1\n' "$2" "$1" > "$tmp"
  chown root:root "$tmp"; chmod 0644 "$tmp"
  mv -f -- "$tmp" "/etc/cron.d/pneuma-gate-$1"
}
cron_file janitor '*/30 * * * *'
cron_file guard '* * * * *'
status_out="$(/usr/local/bin/pneuma-gate-runner status)"
printf '%s\n' "$status_out"
# The disk guard assumes the per-unit write cap: refuse to finish an install that cannot apply it.
if ! grep -q '^io-cap: /dev/' <<<"$status_out"; then
  echo "ci-builder-gate-host: FAILED: no IOWriteBandwidthMax device resolves on this host (see 'io-cap:' above); set PNEUMA_GATE_IO_DEVICE" >&2
  exit 1
fi
# [host-only-end]
