#!/usr/bin/env bash
# ci-builder-gate.sh — provision remote pre-push gates: the runner + per-repo
# profiles on the build host, and the client on this dev box.
#
#   bash ci-builder-gate.sh                  # host + client (idempotent)
#   bash ci-builder-gate.sh --host-only
#   bash ci-builder-gate.sh --client-only
#   bash ci-builder-gate.sh --host-only --stage submit-path   # account, entry, sudoers, keys, from.conf; NOT the runner
#   bash ci-builder-gate.sh --host-only --stage runner        # runner, profiles, janitor; NOT the submit path
#   bash ci-builder-gate.sh --local-host --acceptance   # provision THIS machine (a VM/container for the acceptance test; root)
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
do_host=1; do_client=1; local_host=0; acceptance=0; stage=all
while [ $# -gt 0 ]; do
  case "$1" in
    --host-only) do_client=0; shift;;
    --client-only) do_host=0; shift;;
    --local-host) do_client=0; local_host=1; shift;;
    --acceptance) acceptance=1; shift;;
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

# --local-host provisions THIS machine without the approved-host check the ssh path makes. It exists for the
# acceptance test only, so it needs the explicit --acceptance flag, and it refuses on the approved builder
# itself (or on any host whose name is the approved one): a real host is provisioned over ssh. The submit path
# (sshd drop-in, sudoers, entry) needs the host's sshd and key list, so the local path is runner-only.
if [ "$local_host" = 1 ]; then
  [ "$acceptance" = 1 ] || { echo "refusing: --local-host is for the acceptance test only (add --acceptance); a real host is provisioned over ssh" >&2; exit 2; }
  [ "$(hostname)" != "$APPROVED_HOST" ] || { echo "refusing: this IS the approved builder ($APPROVED_HOST); --local-host --acceptance never runs on a real host" >&2; exit 2; }
  [ "$do_submit" = 0 ] || { echo "refusing: --local-host provisions the runner only; add --stage runner" >&2; exit 2; }
fi
if [ "$acceptance" = 1 ] && [ "$local_host" != 1 ]; then echo "refusing: --acceptance only goes with --local-host" >&2; exit 2; fi

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
    # root-side step, from a root-owned staging dir, without ssh.
    STAGE="$(set -euo pipefail; install -d -o root -g root -m 0700 /var/lib/pneuma-gate-install && mktemp -d /var/lib/pneuma-gate-install/stage.XXXXXX)"
    [[ "$STAGE" =~ ^/var/lib/pneuma-gate-install/stage\.[A-Za-z0-9]{6}$ ]] \
      || { echo "refusing: unexpected staging path '$STAGE'" >&2; exit 1; }
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

    # The root-side step (users, directories, profiles, the runner, the crons): ci-builder-gate-host.sh, on stdin.
    if [ "$do_runner" = 1 ]; then
      ssh "$HOST" "bash -s -- '$STAGE'" < "$REPO_DIR/ci-builder-gate-host.sh"
    fi
  fi
  # [host-only-end]
fi
