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
  # The submission entry point and its forced-command keys (GATE-DEDUP-1 identity): the
  # submitter is the id the key line forces, never something the client sends.
  # The entry is root-owned, whatever the dev box's uid is: rsync -a would carry the local owner.
  rsync -a "$REPO_DIR/bin/pneuma-gate-entry" "$HOST:/tmp/pneuma-gate-entry.new"
  rsync -a "$REPO_DIR/gate-submit-keys" "$HOST:/tmp/pneuma-gate-submit-keys"
  # STAGED MIGRATION (PR #20): stage 1 installs the account, the entry, the keys, the sudoers rule and
  # the sshd Match block; the old root path keeps working until the lanes' ssh config switches (stage 2);
  # then the strict runner is deployed (stage 3). See the PR body for the steps.
  ssh "$HOST" 'set -euo pipefail
    install -o root -g root -m 0755 /tmp/pneuma-gate-entry.new /usr/local/bin/pneuma-gate-entry
    rm -f /tmp/pneuma-gate-entry.new
    id pneuma-submit >/dev/null 2>&1 || useradd --system --create-home --home-dir /var/lib/pneuma-submit --shell /bin/bash pneuma-submit
    # Authorized keys live OUTSIDE the submitter home, root-owned: sshd reads them via the Match block below.
    install -d -o root -g root -m 0755 /etc/ssh/authorized_keys
    # from= comes from a HOST-LOCAL file (name address), never from the repo: a key line names it in its 4th field.
    FROM_CONF=/etc/pneuma-gate/from.conf
    : > /tmp/pneuma-submit-authorized.new
    while read -r id type key fromname; do
      [ -n "$id" ] || continue
      from=""
      if [ -n "${fromname:-}" ]; then
        addr="$(awk -v n="$fromname" "\$1 == n { print \$2 }" "$FROM_CONF" 2>/dev/null || true)"
        [ -n "$addr" ] || { echo "refused: from-name $fromname has no address in $FROM_CONF" >&2; rm -f /tmp/pneuma-submit-authorized.new /tmp/pneuma-gate-submit-keys; exit 1; }
        from="from=\"$addr\","
      fi
      printf "%srestrict,command=\"/usr/local/bin/pneuma-gate-entry --submitter %s\" %s %s\n" "$from" "$id" "$type" "$key" >> /tmp/pneuma-submit-authorized.new
    done < <(grep -v "^#" /tmp/pneuma-gate-submit-keys)
    install -o root -g root -m 0644 /tmp/pneuma-submit-authorized.new /etc/ssh/authorized_keys/pneuma-submit
    rm -f /tmp/pneuma-submit-authorized.new /tmp/pneuma-gate-submit-keys
    # sshd: the submitter reads keys from /etc/ssh/authorized_keys/%u. Validated (sshd -t, and the effective
    # value by sshd -T) before any reload; reload, never restart; removed again if validation fails.
    printf "Match User pneuma-submit\n    AuthorizedKeysFile /etc/ssh/authorized_keys/%%u\n" > /etc/ssh/sshd_config.d/50-pneuma-submit.conf
    chmod 0644 /etc/ssh/sshd_config.d/50-pneuma-submit.conf
    if sshd -t && sshd -T -C user=pneuma-submit,host=localhost,addr=127.0.0.1 2>/dev/null | grep -qx "authorizedkeysfile /etc/ssh/authorized_keys/%u"; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || echo "sshd reload failed: the Match block applies at the next reload" >&2
    else
      rm -f /etc/ssh/sshd_config.d/50-pneuma-submit.conf
      echo "refused: sshd does not take the submitter Match block; not applied" >&2; exit 1
    fi
    # the ONE elevation, restricted to the three verbs the gate client sends (entry validates the rest)
    printf "Defaults!/usr/local/bin/pneuma-gate-runner env_reset\npneuma-submit ALL=(root) NOPASSWD: /usr/local/bin/pneuma-gate-runner status *, /usr/local/bin/pneuma-gate-runner have *, /usr/local/bin/pneuma-gate-runner run *\n" > /tmp/pneuma-submit.sudoers
    visudo -cf /tmp/pneuma-submit.sudoers >/dev/null
    install -o root -g root -m 0440 /tmp/pneuma-submit.sudoers /etc/sudoers.d/pneuma-submit
    rm -f /tmp/pneuma-submit.sudoers'
  ssh "$HOST" 'mkdir -p /usr/local/lib/pneuma-gate/profiles'
  rsync -a --delete "$REPO_DIR/gate-profiles/" "$HOST:/usr/local/lib/pneuma-gate/profiles/"
  rsync -a "$REPO_DIR/bin/pneuma-gate-runner" "$HOST:/usr/local/bin/pneuma-gate-runner"
  ssh "$HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
id pneuma-gate >/dev/null 2>&1 || useradd --system --home-dir /var/lib/pneuma-gate --shell /usr/sbin/nologin pneuma-gate
install -d -o pneuma-gate -g pneuma-gate -m 0755 /var/lib/pneuma-gate
chmod 0755 /usr/local/bin/pneuma-gate-runner
# They run as root (the runner sources the profiles as root), so nothing the
# unprivileged gate user can write may ever be on that path: root owns everything,
# directories 0755, files 0644.
chown root:root /usr/local/bin/pneuma-gate-runner && chmod 0755 /usr/local/bin/pneuma-gate-runner
chown -R root:root /usr/local/lib/pneuma-gate
find /usr/local/lib/pneuma-gate -type d -exec chmod 0755 {} +
find /usr/local/lib/pneuma-gate -type f -exec chmod 0644 {} +
# Janitor: reap dead runs / stale keep-refs even when no gate is starting.
printf '*/30 * * * * root /usr/local/bin/pneuma-gate-runner janitor >/dev/null 2>&1\n' > /etc/cron.d/pneuma-gate-janitor
chmod 0644 /etc/cron.d/pneuma-gate-janitor
/usr/local/bin/pneuma-gate-runner status
REMOTE
  # [host-only-end]
fi
