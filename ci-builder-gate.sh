#!/usr/bin/env bash
# ci-builder-gate.sh — provision remote pre-push gates: the runner + per-repo
# profiles on the build host, and the client on this dev box.
#
#   bash ci-builder-gate.sh                  # host + client (idempotent)
#   bash ci-builder-gate.sh --host-only
#   bash ci-builder-gate.sh --client-only
#   bash ci-builder-gate.sh --local-host     # provision THIS machine as the builder (root; fresh-host test)
#   PNEUMA_GATE_HOST=other bash ci-builder-gate.sh
#
# Touches ONLY: /usr/local/bin/pneuma-gate-runner, /usr/local/lib/pneuma-gate/,
# /var/lib/pneuma-gate/, /var/lib/pneuma-gate-state/, the unprivileged `pneuma-gate` user (it owns
# the object store only; every gate itself runs as a per-run systemd DynamicUser) and one cron file.
# It never restarts k3s, the GitHub runner services, or the VPN. Refuses to
# mutate any host whose hostname is not the approved builder.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${PNEUMA_GATE_HOST:-ci-builder}"
APPROVED_HOST="${PNEUMA_GATE_EXPECT_HOST:-vmi3387590}"
CLIENT_DEST="${PNEUMA_GATE_CLIENT_DEST:-$HOME/.local/bin}"
do_host=1; do_client=1; local_host=0
for a in "$@"; do
  case "$a" in
    --host-only) do_client=0;; --client-only) do_host=0;;
    --local-host) do_client=0; local_host=1;;
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
  # [host-only-begin]
  if [ "$local_host" = 1 ]; then
    # This machine IS the builder (a VM or container provisioned for the acceptance test): the same
    # root-side step, from a root-owned staging dir, without ssh. The submit path (sshd drop-in, sudoers,
    # entry) is installed only over ssh: it needs the host's sshd and the key list.
    STAGE="$(set -euo pipefail; install -d -o root -g root -m 0700 /var/lib/pneuma-gate-install && mktemp -d /var/lib/pneuma-gate-install/stage.XXXXXX)"
    case "$STAGE" in /var/lib/pneuma-gate-install/stage.??????) ;; *) echo "refusing: unexpected staging path '$STAGE'" >&2; exit 1;; esac
    trap 'rm -rf -- "$STAGE"' EXIT
    install -m 0755 "$REPO_DIR/bin/pneuma-gate-runner" "$STAGE/pneuma-gate-runner"
    mkdir "$STAGE/profiles" && cp -a "$REPO_DIR/gate-profiles/." "$STAGE/profiles/"
    bash "$REPO_DIR/ci-builder-gate-host.sh" "$STAGE"
  else
    actual="$(ssh -o BatchMode=yes "$HOST" hostname)"
    [ "$actual" = "$APPROVED_HOST" ] || { echo "refusing: $HOST is '$actual', not the approved builder $APPROVED_HOST" >&2; exit 1; }
    # Every file for the host goes through ONE root-owned 0700 staging dir made by mktemp on the host
    # (never a predictable name). The path is validated before use and removed on exit.
    STAGE="$(ssh -o BatchMode=yes "$HOST" 'set -euo pipefail; install -d -o root -g root -m 0700 /var/lib/pneuma-gate-install && mktemp -d /var/lib/pneuma-gate-install/stage.XXXXXX')"
    case "$STAGE" in
      /var/lib/pneuma-gate-install/stage.??????) ;;
      *) echo "refusing: unexpected staging path from $HOST: '$STAGE'" >&2; exit 1;;
    esac
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

    # The root-side step (users, directories, profiles, the runner, the crons): ci-builder-gate-host.sh, on stdin.
    ssh "$HOST" "bash -s -- '$STAGE'" < "$REPO_DIR/ci-builder-gate-host.sh"
  fi
  # [host-only-end]
fi
