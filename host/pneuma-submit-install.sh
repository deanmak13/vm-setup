#!/usr/bin/env bash
# host/pneuma-submit-install.sh — root-side installer for the gate submit path (PR #20).
#
# Runs ON THE BUILD HOST as root, from a root-owned 0700 staging dir that ci-builder-gate.sh made with
# mktemp:   bash pneuma-submit-install.sh STAGE_DIR
# STAGE_DIR holds pneuma-gate-entry (the forced-command entry) and gate-submit-keys (the key list).
#
# Two phases, no exceptions:
#   1. VALIDATE. Inputs are checked and every candidate config is rendered and checked in a private work
#      dir inside the staging dir. Nothing live changes in this phase: a refusal leaves the live state as it was.
#   2. APPLY. Each live file is saved, then replaced by an atomic rename. The live checks (visudo -c,
#      sshd -t, the effective sshd values) and the sshd reload run after the writes and are the LAST steps.
#      Any failure restores every saved file (removing it if it did not exist before) and exits 1 loudly.
#      There is no path that leaves an old or partial config live without saying so.
#
# Scope: the sshd drop-in ends with `Match all`, so the override cannot reach any other user; the sudoers
# rule names exactly the three verbs of the runner. Temp files are mktemp names inside the root-owned
# staging dir or beside their target (dot-prefixed, so sudo and sshd ignore them if left behind).
set -euo pipefail

FROM_CONF=/etc/pneuma-gate/from.conf
ENTRY=/usr/local/bin/pneuma-gate-entry
KEYS_DIR=/etc/ssh/authorized_keys
KEYS="$KEYS_DIR/pneuma-submit"
DROPIN=/etc/ssh/sshd_config.d/50-pneuma-submit.conf
SUDOERS=/etc/sudoers.d/pneuma-submit
RUNNER=/usr/local/bin/pneuma-gate-runner

die() { echo "refused: $*" >&2; exit 1; }

# The ONE sudo rule: the entry may run exactly the three verbs of the runner, nothing else. Rendered here
# and only here; tests/gate-real-sudo.check.sh reads it back through --render-sudoers (no copy elsewhere).
render_sudoers() {
  printf 'Defaults!%s env_reset\npneuma-submit ALL=(root) NOPASSWD: %s status *, %s have *, %s run *\n' \
    "$RUNNER" "$RUNNER" "$RUNNER" "$RUNNER" > "$1"
}

# A from-address must be one IPv4/IPv6 address or CIDR from a strict allowlist. Anything else (a quote, a comma,
# a space, a newline, a hostname) could change the key options, so it is refused, never escaped.
# A prefix shorter than /16 (IPv4) or /32 (IPv6) is refused: that admits most of the internet, including
# 0.0.0.0/0 and ::/0. A single address (no prefix) is always fine.
valid_addr() {
  local a="$1" oct='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])' v4 v6 prefix
  v4="^$oct\.$oct\.$oct\.$oct(/(3[0-2]|[12]?[0-9]))?$"
  v6='^[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}(/(12[0-8]|1[01][0-9]|[1-9]?[0-9]))?$'
  if [[ "$a" =~ $v4 ]]; then
    prefix="${a#*/}"; [ "$prefix" = "$a" ] && return 0
    [ "$prefix" -ge 16 ]
  elif [[ "$a" =~ $v6 ]]; then
    prefix="${a#*/}"; [ "$prefix" = "$a" ] && return 0
    [ "$prefix" -ge 32 ]
  else
    return 1
  fi
}

# --render-sudoers OUT: write the candidate rule and exit. Touches nothing live; needs no staging dir.
if [ "${1:-}" = "--render-sudoers" ]; then
  [ "$#" -eq 2 ] || { echo "usage: pneuma-submit-install.sh --render-sudoers OUT" >&2; exit 2; }
  render_sudoers "$2"
  exit 0
fi
if [ "$#" -ne 1 ]; then echo "usage: pneuma-submit-install.sh STAGE_DIR" >&2; exit 2; fi
STAGE="$1"

# ---------------------------------------------------------------- phase 1: validate
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -d "$STAGE" ] && [ ! -L "$STAGE" ] || die "staging dir $STAGE is not a real directory"
[ "$(stat -c '%U %a' "$STAGE")" = "root 700" ] || die "staging dir $STAGE must be root-owned mode 700"
for f in "$STAGE/pneuma-gate-entry" "$STAGE/gate-submit-keys"; do
  [ -f "$f" ] && [ ! -L "$f" ] || die "missing or non-regular staged file $f"
done
bash -n "$STAGE/pneuma-gate-entry" || die "staged entry does not parse"

WORK="$(mktemp -d "$STAGE/work.XXXXXX")"
KEEP_WORK=0
RESCUE_ROOT=/var/lib/pneuma-gate-install-rescue
RESCUE_DIR=""
trap '[ "$KEEP_WORK" = 1 ] || rm -rf -- "$WORK"' EXIT
SAVED="$WORK/saved"
mkdir "$SAVED"

# from.conf: only needed when a key line names a from-address. Root-owned, mode 0600 or 0440, never a symlink.
FROM_OK=0
check_from_conf() {
  [ -f "$FROM_CONF" ] && [ ! -L "$FROM_CONF" ] || die "$FROM_CONF is missing (a key line names a from-address)"
  case "$(stat -c '%U:%G:%a' "$FROM_CONF")" in
    root:root:600|root:root:440) ;;
    *) die "$FROM_CONF must be root:root mode 0600 or 0440" ;;
  esac
  FROM_OK=1
}

RENDERED="$WORK/authorized_keys"
: > "$RENDERED"
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  read -r id type key fromname extra <<<"$line"
  [ -z "${extra:-}" ] || die "key line for '${id:-?}' has more than four fields"
  [[ "${id:-}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "bad submitter id '${id:-}'"
  [[ "${type:-}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$ ]] || die "bad key type for $id"
  [[ "${key:-}" =~ ^[A-Za-z0-9+/]+=*$ ]] || die "bad key material for $id"
  # from= is MANDATORY on every key line: a key that can log in from anywhere is refused at install time.
  [ -n "${fromname:-}" ] || die "key line for '$id' has no from-name (from= is mandatory on every submitter key)"
  [[ "$fromname" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "bad from-name for $id"
  [ "$FROM_OK" = 1 ] || check_from_conf
  # exactly "name address": a line with more fields is refused, never silently truncated
  read -r fc_nf addr <<<"$(awk -v n="$fromname" '$1 == n { print NF, $2; exit }' "$FROM_CONF")"
  [ -n "${addr:-}" ] || die "from-name '$fromname' (for $id) has no address in $FROM_CONF"
  [ "$fc_nf" = 2 ] || die "from-name '$fromname' line in $FROM_CONF must be exactly 'name address'"
  valid_addr "$addr" || die "from-address for '$fromname' is not an IPv4/IPv6 address or CIDR"
  from="from=\"$addr\","
  printf '%srestrict,command="/usr/local/bin/pneuma-gate-entry --submitter %s" %s %s\n' \
    "$from" "$id" "$type" "$key" >> "$RENDERED"
done < "$STAGE/gate-submit-keys"
[ -s "$RENDERED" ] || die "no submitter keys in gate-submit-keys (refusing to empty the live key list)"

CAND_DROPIN="$WORK/50-pneuma-submit.conf"
printf 'Match User pneuma-submit\n    AuthorizedKeysFile %s/%%u\nMatch all\n' "$KEYS_DIR" > "$CAND_DROPIN"

CAND_SUDOERS="$WORK/pneuma-submit.sudoers"
render_sudoers "$CAND_SUDOERS"
visudo -cf "$CAND_SUDOERS" >/dev/null 2>&1 || die "rendered sudoers rule does not validate"

# ---------------------------------------------------------------- phase 2: apply
# Save the current state of every live target first (or record that it did not exist).
save() {
  local dest="$1" name="$2"
  if [ -e "$dest" ]; then cp -p -- "$dest" "$SAVED/$name"; : > "$SAVED/$name.exists"; fi
}
# Put a saved copy back (or remove the file if it did not exist before). Atomic where it writes.
# Returns non-zero when the restore itself fails: the caller then keeps the saved copies.
restore() {
  local dest="$1" name="$2" tmp
  if [ -e "$SAVED/$name.exists" ]; then
    tmp="$(mktemp "$(dirname "$dest")/.restore.XXXXXX")" || return 1
    cp -p -- "$SAVED/$name" "$tmp" && mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
  else
    rm -f -- "$dest" || return 1
  fi
}
# Write a candidate to its live path via a same-directory temp file and rename (never a partial file).
install_atomic() {
  local src="$1" dest="$2" mode="$3" tmp
  tmp="$(mktemp "$(dirname "$dest")/.install.XXXXXX")" || return 1
  install -o root -g root -m "$mode" -- "$src" "$tmp" && mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

rollback() {
  local failed=0
  echo "pneuma-submit-install: FAILED: $1; restoring the previous state" >&2
  restore "$ENTRY" entry || { failed=1; echo "pneuma-submit-install: RESTORE FAILED for $ENTRY" >&2; }
  restore "$KEYS" keys || { failed=1; echo "pneuma-submit-install: RESTORE FAILED for $KEYS" >&2; }
  restore "$DROPIN" dropin || { failed=1; echo "pneuma-submit-install: RESTORE FAILED for $DROPIN" >&2; }
  restore "$SUDOERS" sudoers || { failed=1; echo "pneuma-submit-install: RESTORE FAILED for $SUDOERS" >&2; }
  if [ "$failed" = 1 ]; then
    # The saved copies are the only good record of the previous state. They move OUT of the staging dir (the
    # caller removes that on exit) into a root-only rescue dir that survives the run. The rescue root sits
    # outside the pneuma-gate user's tree, so that account cannot rename or remove it.
    if persist_rescue; then
      echo "pneuma-submit-install: the previous state is NOT fully restored. Saved copies kept at $RESCUE_DIR - restore them by hand before anything else" >&2
    else
      echo "pneuma-submit-install: the previous state is NOT fully restored AND the saved copies could not be persisted; they are being discarded with the staging dir. Restore by hand from the live files." >&2
    fi
  else
    echo "pneuma-submit-install: previous state restored" >&2
  fi
  exit 1
}

# Copy the saved copies to RESCUE_ROOT/<utc-timestamp>.XXXXXX (root 0700). Sets RESCUE_DIR and returns non-zero
# if the copy fails. On success the staging copies are dropped, so only the rescue copy remains.
persist_rescue() {
  local ts
  install -d -o root -g root -m 0700 "$RESCUE_ROOT" || return 1
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  RESCUE_DIR="$(mktemp -d "$RESCUE_ROOT/$ts.XXXXXX")" || return 1
  cp -a -- "$SAVED"/. "$RESCUE_DIR"/ || return 1
  # cp -a carries the saved directory's own mode onto the rescue dir: re-apply the root-only mode afterwards
  chown root:root "$RESCUE_DIR" && chmod 0700 "$RESCUE_DIR" || return 1
  KEEP_WORK=0
  return 0
}

install -d -o root -g root -m 0755 "$KEYS_DIR" || die "cannot create $KEYS_DIR"
save "$ENTRY" entry
save "$KEYS" keys
save "$DROPIN" dropin
save "$SUDOERS" sudoers

install_atomic "$STAGE/pneuma-gate-entry" "$ENTRY" 0755 || rollback "entry install"
install_atomic "$RENDERED" "$KEYS" 0644 || rollback "submitter keys install"
install_atomic "$CAND_DROPIN" "$DROPIN" 0644 || rollback "sshd drop-in install"
install_atomic "$CAND_SUDOERS" "$SUDOERS" 0440 || rollback "sudoers install"

visudo -c >/dev/null 2>&1 || rollback "live sudoers check (visudo -c) failed"
sshd -t >/dev/null 2>&1 || rollback "sshd -t rejects the live config"

eff="$(sshd -T -C user=pneuma-submit,host=localhost,addr=127.0.0.1 2>/dev/null)" \
  || rollback "sshd -T failed for pneuma-submit"
grep -qx "authorizedkeysfile $KEYS_DIR/%u" <<<"$eff" \
  || rollback "pneuma-submit does not get the submitter keys file (Include missing from sshd_config?)"
eff_root="$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null)" \
  || rollback "sshd -T failed for user root"
if grep -q "^authorizedkeysfile $KEYS_DIR/" <<<"$eff_root"; then
  rollback "the submitter override leaks to user root"
fi

# Reload is the last step. A failed reload leaves the previous in-memory config live; it is a failure, not a warning.
systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 \
  || rollback "sshd reload failed"

echo "pneuma-submit-install: applied: $(wc -l < "$RENDERED") submitter key(s), entry, sshd drop-in, sudoers"
