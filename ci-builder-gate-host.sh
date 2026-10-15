#!/usr/bin/env bash
# ci-builder-gate-host.sh — the root-side provisioning of the remote gate on the build host.
# Run by ci-builder-gate.sh on the host (over ssh on stdin, or directly with --local-host --acceptance):
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
#   /var/lib/pneuma-gate-results    root 0700: the verdict files (created by the runner)
# A gate itself runs as a transient service with DynamicUser=yes: a unique uid per run, so no run
# can read or write another's files, processes or sockets.
set -euo pipefail
STAGE="${1:?usage: ci-builder-gate-host.sh STAGE}"
[[ "$STAGE" =~ ^/var/lib/pneuma-gate-install/stage\.[A-Za-z0-9]{6}$ ]] || { echo "refusing: bad stage $STAGE" >&2; exit 1; }
# [host-only-begin]
id pneuma-gate >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pneuma-gate --shell /usr/sbin/nologin pneuma-gate
install -d -o root -g root -m 0755 /var/lib/pneuma-gate /var/lib/pneuma-gate/envs /var/lib/pneuma-gate/wheels /var/lib/pneuma-gate/queue
install -d -o pneuma-gate -g pneuma-gate -m 0755 /var/lib/pneuma-gate/repos
install -d -o root -g root -m 0700 /var/lib/pneuma-gate-state /var/lib/pneuma-gate-state/runs /var/lib/pneuma-gate-state/in
# They run as root (the runner sources the profiles as root): root owns everything, dirs 0755, files 0644,
# set in the root-owned staging copy BEFORE anything reaches the live path.
chown -R root:root "$STAGE/profiles"
find "$STAGE/profiles" -type d -exec chmod 0755 {} +
find "$STAGE/profiles" -type f -exec chmod 0644 {} +
install -d -o root -g root -m 0755 /usr/local/lib/pneuma-gate
# Profiles: one versioned directory per install under profiles.d/, and a live SYMLINK at profiles that is moved
# by a single rename(2). The new tree is complete before the link moves, so the live path is never absent or
# partial; a failed swap leaves the previous link live and says so. The runner reads through the link.
ROOT=/usr/local/lib/pneuma-gate
PROFILES="$ROOT/profiles"
install -d -o root -g root -m 0755 "$ROOT" "$ROOT/profiles.d"
if [ -d "$PROFILES" ] && [ ! -L "$PROFILES" ]; then
  # one-time migration from the old real directory: kept as profiles.d/legacy, not deleted
  mv -T -- "$PROFILES" "$ROOT/profiles.d/legacy"
fi
prev="$(readlink "$PROFILES" 2>/dev/null || true)"
ver="$(mktemp -d "$ROOT/profiles.d/v.XXXXXX")"
if ! rsync -a "$STAGE/profiles/" "$ver/"; then
  rm -rf -- "$ver"
  echo "refused: profiles copy failed; the live profiles are unchanged" >&2
  exit 1
fi
new_link="$(mktemp -u "$ROOT/.profiles-link.XXXXXX")"
ln -s -- "profiles.d/$(basename "$ver")" "$new_link"
if ! mv -T -- "$new_link" "$PROFILES"; then
  rm -f -- "$new_link"
  rm -rf -- "$ver"
  echo "refused: profiles swap failed; the previous profiles remain live (no change)" >&2
  exit 1
fi
# keep the new version and the one before it (a hand rollback target); prune the rest, never legacy
keep_new="$(basename "$ver")"
keep_prev="$(basename "${prev:-none}")"
for d in "$ROOT"/profiles.d/*; do
  case "$(basename "$d")" in
    "$keep_new"|"$keep_prev"|legacy) continue;;
  esac
  rm -rf -- "$d"
done
# The runner: atomic replace, mktemp beside the target.
runner_tmp="$(mktemp /usr/local/bin/.pneuma-gate-runner.XXXXXX)"
install -o root -g root -m 0755 "$STAGE/pneuma-gate-runner" "$runner_tmp"
mv -f -- "$runner_tmp" /usr/local/bin/pneuma-gate-runner
# Janitor: the runner's own leftovers (queue tickets, markers, staged bundles, old keep-refs, stale loopback
# routes, old verdict files and job logs) — it deletes no run directory. Guard: stops gate units whose runner is
# gone and every gate unit when the disk is low. Both atomic; a dot-named temp file is ignored by cron.d while it exists.
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
