#!/usr/bin/env bash
# ci-builder-gate.sh — provision remote pre-push gates: the runner + per-repo
# profiles on the build host, and the client on this dev box.
#
#   bash ci-builder-gate.sh                  # host + client (idempotent)
#   bash ci-builder-gate.sh --host-only
#   bash ci-builder-gate.sh --client-only
#   bash ci-builder-gate.sh --host-only --stage submit-path   # account, entry, sudoers, keys, from.conf; NOT the runner
#   bash ci-builder-gate.sh --host-only --stage runner        # runner, profiles, janitor; NOT the submit path
#   PNEUMA_GATE_HOST=other bash ci-builder-gate.sh
#
# Touches ONLY: /usr/local/bin/pneuma-gate-runner, /usr/local/lib/pneuma-gate/,
# /var/lib/pneuma-gate/, the unprivileged `pneuma-gate` user and one cron file.
# It never restarts k3s, the GitHub runner services, or the VPN. Refuses to
# mutate any host whose hostname is not the approved builder.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${PNEUMA_GATE_HOST:-ci-builder}"
APPROVED_HOST="${PNEUMA_GATE_EXPECT_HOST:-vmi3387590}"
CLIENT_DEST="${PNEUMA_GATE_CLIENT_DEST:-$HOME/.local/bin}"
do_host=1; do_client=1; stage=all
while [ $# -gt 0 ]; do
  case "$1" in
    --host-only) do_client=0; shift;;
    --client-only) do_host=0; shift;;
    --stage) stage="${2:-}"; shift 2;;
    *) echo "unknown argument $1" >&2; exit 2;;
  esac
done
# --stage submit-path: the pneuma-submit account, the entry, the sudoers rule, the keys and from.conf ONLY (the
#   runner, profiles and janitor are not touched, so in-flight lanes on the root path keep the old runner).
# --stage runner:      the runner, profiles and janitor ONLY (the submit path is not touched).
# --stage all:         both, submit path first (the default).
case "$stage" in
  submit-path) do_submit=1; do_runner=0;;
  runner) do_submit=0; do_runner=1;;
  all) do_submit=1; do_runner=1;;
  *) echo "unknown stage '$stage' (use submit-path, runner or all)" >&2; exit 2;;
esac

if [ "$do_client" = 1 ]; then
  mkdir -p "$CLIENT_DEST"
  # atomic: a temp file in the destination dir, then a rename (never a partially written client)
  client_tmp="$(mktemp "$CLIENT_DEST/.pneuma-remote-gate.XXXXXX")"
  install -m 0755 "$REPO_DIR/bin/pneuma-remote-gate" "$client_tmp"
  mv -f -- "$client_tmp" "$CLIENT_DEST/pneuma-remote-gate"
  printf 'client: %s/pneuma-remote-gate\n' "$CLIENT_DEST"
fi

if [ "$do_host" = 1 ]; then
  actual="$(ssh -o BatchMode=yes "$HOST" hostname)"
  [ "$actual" = "$APPROVED_HOST" ] || { echo "refusing: $HOST is '$actual', not the approved builder $APPROVED_HOST" >&2; exit 1; }
  # [host-only-begin]
  # Every file for the host goes through ONE root-owned 0700 staging dir made by mktemp on the host
  # (never a predictable name). The path is validated before use and removed on exit.
  STAGE="$(ssh -o BatchMode=yes "$HOST" 'set -euo pipefail; install -d -o root -g root -m 0700 /var/lib/pneuma-gate-install && mktemp -d /var/lib/pneuma-gate-install/stage.XXXXXX')"
  # exactly one mktemp name under the root dir: six alphanumerics, no slash, no dots
  [[ "$STAGE" =~ ^/var/lib/pneuma-gate-install/stage\.[A-Za-z0-9]{6}$ ]] \
    || { echo "refusing: unexpected staging path from $HOST: '$STAGE'" >&2; exit 1; }
  trap 'ssh -o BatchMode=yes "$HOST" "rm -rf -- $STAGE" >/dev/null 2>&1 || true' EXIT

  # Stage everything. Ownership on the staged copies does not matter: the root-side steps set it.
  if [ "$do_submit" = 1 ]; then
    rsync -a "$REPO_DIR/bin/pneuma-gate-entry" "$REPO_DIR/gate-submit-keys" \
      "$REPO_DIR/host/pneuma-submit-install.sh" "$HOST:$STAGE/"
  fi
  if [ "$do_runner" = 1 ]; then
    rsync -a "$REPO_DIR/bin/pneuma-gate-runner" "$HOST:$STAGE/pneuma-gate-runner"
    rsync -a "$REPO_DIR/gate-profiles/" "$HOST:$STAGE/profiles/"
  fi

  # STAGED MIGRATION (PR #20): the submit path (account, entry, sudoers, keys, sshd Match block, from.conf) is
  # validated and rolled back as one unit by host/pneuma-submit-install.sh. The old root path keeps working
  # until the lanes' ssh config switches; then the runner is deployed (--stage runner). See the PR body.
  if [ "$do_submit" = 1 ]; then
    ssh "$HOST" "bash '$STAGE/pneuma-submit-install.sh' '$STAGE'"
  fi

  if [ "$do_runner" = 1 ]; then
  ssh "$HOST" "bash -s -- '$STAGE'" <<'REMOTE'
set -euo pipefail
STAGE="$1"
[[ "$STAGE" =~ ^/var/lib/pneuma-gate-install/stage\.[A-Za-z0-9]{6}$ ]] || { echo "refusing: bad stage $STAGE" >&2; exit 1; }
id pneuma-gate >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pneuma-gate --shell /usr/sbin/nologin pneuma-gate
install -d -o pneuma-gate -g pneuma-gate -m 0755 /var/lib/pneuma-gate
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
# Janitor: reap dead runs / stale keep-refs even when no gate is starting. Atomic; the dot-named temp file
# is ignored by cron.d while it exists.
cron_tmp="$(mktemp /etc/cron.d/.pneuma-gate-janitor.XXXXXX)"
printf '*/30 * * * * root /usr/local/bin/pneuma-gate-runner janitor >/dev/null 2>&1\n' > "$cron_tmp"
chown root:root "$cron_tmp"
chmod 0644 "$cron_tmp"
mv -f -- "$cron_tmp" /etc/cron.d/pneuma-gate-janitor
/usr/local/bin/pneuma-gate-runner status
REMOTE
  fi
  # [host-only-end]
fi
