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
  install -m 0755 "$REPO_DIR/bin/pneuma-remote-gate" "$CLIENT_DEST/pneuma-remote-gate"
  printf 'client: %s/pneuma-remote-gate\n' "$CLIENT_DEST"
fi

if [ "$do_host" = 1 ]; then
  actual="$(ssh -o BatchMode=yes "$HOST" hostname)"
  [ "$actual" = "$APPROVED_HOST" ] || { echo "refusing: $HOST is '$actual', not the approved builder $APPROVED_HOST" >&2; exit 1; }
  # [host-only-begin]
  ssh "$HOST" 'mkdir -p /usr/local/lib/pneuma-gate/profiles'
  rsync -a --delete "$REPO_DIR/gate-profiles/" "$HOST:/usr/local/lib/pneuma-gate/profiles/"
  rsync -a "$REPO_DIR/bin/pneuma-gate-runner" "$HOST:/usr/local/bin/pneuma-gate-runner"
  ssh "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
id pneuma-gate >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pneuma-gate --shell /usr/sbin/nologin pneuma-gate
install -d -o pneuma-gate -g pneuma-gate -m 0755 /var/lib/pneuma-gate
chmod 0755 /usr/local/bin/pneuma-gate-runner
chmod -R a+rX /usr/local/lib/pneuma-gate
# Janitor: reap dead runs / stale keep-refs even when no gate is starting.
printf '*/30 * * * * root /usr/local/bin/pneuma-gate-runner janitor >/dev/null 2>&1\n' > /etc/cron.d/pneuma-gate-janitor
chmod 0644 /etc/cron.d/pneuma-gate-janitor
/usr/local/bin/pneuma-gate-runner status
REMOTE
  # [host-only-end]
fi
