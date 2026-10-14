#!/usr/bin/env bash
# ci-builder-gate.sh — provision remote pre-push gates: the runner + per-repo
# profiles on the build host, and the client on this dev box.
#
#   bash ci-builder-gate.sh                  # host + client (idempotent)
#   bash ci-builder-gate.sh --host-only
#   bash ci-builder-gate.sh --client-only
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
do_host=1; do_client=1
for a in "$@"; do
  case "$a" in
    --host-only) do_client=0;; --client-only) do_host=0;;
    *) echo "unknown argument $a" >&2; exit 2;;
  esac
done

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
  rsync -a "$REPO_DIR/bin/pneuma-gate-entry" "$REPO_DIR/gate-submit-keys" \
    "$REPO_DIR/host/pneuma-submit-install.sh" "$HOST:$STAGE/"
  rsync -a "$REPO_DIR/bin/pneuma-gate-runner" "$HOST:$STAGE/pneuma-gate-runner"
  rsync -a "$REPO_DIR/gate-profiles/" "$HOST:$STAGE/profiles/"

  # STAGED MIGRATION (PR #20): stage 1 installs the account, the entry, the keys, the sudoers rule and the
  # sshd Match block, all validated and rolled back as one unit (host/pneuma-submit-install.sh). The old
  # root path keeps working until the lanes' ssh config switches (stage 2); then the strict runner is
  # deployed (stage 3). See the PR body for the steps.
  ssh "$HOST" "bash '$STAGE/pneuma-submit-install.sh' '$STAGE'"

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
# Atomic profiles sync: the full new tree is built beside the live one (never into it), then swapped in by two
# renames. If the second rename fails, the old tree is put back and the run fails loudly.
new_profiles="$(mktemp -d /usr/local/lib/pneuma-gate/.profiles-new.XXXXXX)"
rsync -a "$STAGE/profiles/" "$new_profiles/"
old_profiles="$(mktemp -u /usr/local/lib/pneuma-gate/.profiles-old.XXXXXX)"
had_live=0
if [ -e /usr/local/lib/pneuma-gate/profiles ]; then
  mv -T -- /usr/local/lib/pneuma-gate/profiles "$old_profiles"
  had_live=1
fi
if ! mv -T -- "$new_profiles" /usr/local/lib/pneuma-gate/profiles; then
  [ "$had_live" = 1 ] && mv -T -- "$old_profiles" /usr/local/lib/pneuma-gate/profiles
  rm -rf -- "$new_profiles"
  echo "refused: profiles swap failed; the previous profiles were put back" >&2
  exit 1
fi
[ "$had_live" = 1 ] && rm -rf -- "$old_profiles"
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
  # [host-only-end]
fi
