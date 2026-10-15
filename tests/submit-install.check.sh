#!/usr/bin/env bash
# tests/submit-install.check.sh — the submit-path installer (host/pneuma-submit-install.sh) against REAL paths.
#
# Needs docker. The host side starts ONE throwaway container (--rm, no published ports, so nothing listens
# beyond the container) and runs this same file inside it with --inside. Inside, the real installer writes
# the real /etc, /usr/local/bin and /etc/sudoers.d paths. Each scenario starts from a seeded "OLD" state and
# must either succeed with the expected config, or refuse / roll back to the OLD state byte-for-byte.
#
#   bash tests/submit-install.check.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" != "--inside" ]; then
  command -v docker >/dev/null 2>&1 || { echo "FAIL no docker here: cannot run the installer against real paths"; exit 1; }
  out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
  image="${PNEUMA_TEST_IMAGE:-ubuntu:24.04}"
  timeout 900 docker run --rm -v "$REPO:/src:ro" -v "$out:/out" "$image" bash /src/tests/submit-install.check.sh --inside
  exit $?
fi

# ------------------------------------------------------------------ inside the container
INST_SRC=/src/host/pneuma-submit-install.sh
KEYS=/etc/ssh/authorized_keys/pneuma-submit
DROPIN=/etc/ssh/sshd_config.d/50-pneuma-submit.conf
SUDOERS=/etc/sudoers.d/pneuma-submit
ENTRY=/usr/local/bin/pneuma-gate-entry
RUNNER=/usr/local/bin/pneuma-gate-runner
fails=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }
expect() { if "$@"; then :; else return 1; fi; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq sudo openssh-server rsync >/dev/null 2>&1 || { echo "FAIL apt install"; exit 1; }
id pneuma-submit >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash pneuma-submit
useradd -m -s /bin/bash dean-test >/dev/null 2>&1 || true
ssh-keygen -A >/dev/null 2>&1
grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config || { echo "FAIL sshd_config does not Include sshd_config.d"; exit 1; }
mkdir -p /etc/pneuma-gate /var/lib/pneuma-gate-install-test /run/sshd
ssh-keygen -q -t ed25519 -N '' -f /root/k1 && ssh-keygen -q -t ed25519 -N '' -f /root/k2
KEY1="$(awk '{print $1, $2}' /root/k1.pub)"; KEY2="$(awk '{print $1, $2}' /root/k2.pub)"
# the runner stand-in: records who it runs as and what it was given (the real runner is not under test here)
cat > "$RUNNER" <<'STUB'
#!/usr/bin/env bash
echo "uid=$(id -u) sudo_user=${SUDO_USER:-none} args=$*" > /out/runner.txt
STUB
chmod 0755 "$RUNNER"

# shims (PATH-prepended per scenario): visudo failing only on the live check or only on the candidate, and a
# systemctl that fails the reload
mkdir -p /shim/visudo-live-fail /shim/visudo-cf-fail /shim/reload-fail
cat > /shim/visudo-live-fail/visudo <<'S'
#!/usr/bin/env bash
[ "${1:-}" = "-c" ] && exit 1
exec /usr/sbin/visudo "$@"
S
cat > /shim/visudo-cf-fail/visudo <<'S'
#!/usr/bin/env bash
[ "${1:-}" = "-cf" ] && exit 1
exec /usr/sbin/visudo "$@"
S
printf '#!/usr/bin/env bash\nexit 1\n' > /shim/reload-fail/systemctl
# no systemd in the container: a systemctl that succeeds, so the happy path reaches the reload step
printf '#!/usr/bin/env bash\nexit 0\n' > /usr/local/bin/systemctl
chmod 0755 /usr/local/bin/systemctl
chmod +x /shim/*/*

seed_old() {
  mkdir -p /etc/ssh/authorized_keys /etc/sudoers.d /etc/ssh/sshd_config.d
  printf 'OLD-ENTRY\n' > "$ENTRY"; chmod 0755 "$ENTRY"
  printf 'OLD-KEYS\n' > "$KEYS"; chmod 0644 "$KEYS"
  printf 'OLD-DROPIN\n' > "$DROPIN"; chmod 0644 "$DROPIN"
  printf 'OLD-SUDOERS\n' > "$SUDOERS"; chmod 0440 "$SUDOERS"
}
remove_all() { rm -f "$ENTRY" "$KEYS" "$DROPIN" "$SUDOERS"; }
old_intact() {
  [ "$(cat "$ENTRY" 2>/dev/null)" = OLD-ENTRY ] && [ "$(cat "$KEYS" 2>/dev/null)" = OLD-KEYS ] \
    && [ "$(cat "$DROPIN" 2>/dev/null)" = OLD-DROPIN ] && [ "$(cat "$SUDOERS" 2>/dev/null)" = OLD-SUDOERS ] \
    && [ "$(stat -c %a "$ENTRY")" = 755 ] && [ "$(stat -c %a "$KEYS")" = 644 ] && [ "$(stat -c %a "$SUDOERS")" = 440 ] \
    && ! ls -A /etc/ssh/authorized_keys /etc/sudoers.d /etc/ssh/sshd_config.d /usr/local/bin 2>/dev/null | grep -q '^\.'
}
absent_all() { [ ! -e "$ENTRY" ] && [ ! -e "$KEYS" ] && [ ! -e "$DROPIN" ] && [ ! -e "$SUDOERS" ]; }

# a stage like the real one: root 0700 staging dir with the entry, the installer and the keys file
new_stage() {
  local s; s="$(mktemp -d /var/lib/pneuma-gate-install-test/stage.XXXXXX)"; chmod 0700 "$s"
  cp /src/bin/pneuma-gate-entry "$s/"; cp "$INST_SRC" "$s/pneuma-submit-install.sh"
  printf '%s\n' "$s"
}
run_install() { # stage, [PATH prefix]; output to $LOG
  local s="$1" pre="${2:-}"
  if [ -n "$pre" ]; then PATH="$pre:$PATH" bash "$s/pneuma-submit-install.sh" "$s" >"$LOG" 2>&1; else bash "$s/pneuma-submit-install.sh" "$s" >"$LOG" 2>&1; fi
}
LOG=/tmp/submit-install-test.log   # container-local scratch for the installer's output

# ------------------------------------------------------------------ S1: happy path, real sudo and sshd scope
# (keys: one plain line, one line naming a from-address; from.conf is root 0600)
printf 'submit-test 10.0.0.7\n' > /etc/pneuma-gate/from.conf; chmod 0600 /etc/pneuma-gate/from.conf
seed_old
s="$(new_stage)"
printf 'dean-devbox %s submit-test\nci-lane %s submit-test\n' "$KEY1" "$KEY2" > "$s/gate-submit-keys"
run_install "$s"; rc=$?
if [ "$rc" = 0 ]; then pass "S1 happy path installs (rc 0)"; else bad "S1 happy path rc=$rc: $(tail -3 "$LOG")"; fi
grep -q '^from="10.0.0.7",restrict,command="/usr/local/bin/pneuma-gate-entry --submitter ci-lane" ssh-ed25519 ' "$KEYS" && grep -q '^from="10.0.0.7",restrict,command="/usr/local/bin/pneuma-gate-entry --submitter dean-devbox" ' "$KEYS" \
  && pass "S1 from-name renders as from=<address>" || bad "S1 from= rendering: $(cat "$KEYS")"
[ "$(stat -c '%U:%G:%a' "$ENTRY")" = root:root:755 ] && pass "S1 entry is root:root 0755" || bad "S1 entry mode/owner"
[ "$(stat -c '%U:%G:%a' "$SUDOERS")" = root:root:440 ] && pass "S1 sudoers is root:root 0440" || bad "S1 sudoers mode/owner"
[ "$(stat -c '%U:%G:%a' "$KEYS")" = root:root:644 ] && pass "S1 keys file root-owned, outside the home" || bad "S1 keys mode/owner"
grep -q '^Match all$' "$DROPIN" && grep -q '^Match User pneuma-submit$' "$DROPIN" \
  && pass "S1 drop-in closes its Match block (Match all)" || bad "S1 drop-in scope"
eff_pn="$(sshd -T -C user=pneuma-submit,host=localhost,addr=127.0.0.1 2>/dev/null)"
grep -qx "authorizedkeysfile /etc/ssh/authorized_keys/%u" <<<"$eff_pn" \
  && pass "S1 sshd gives pneuma-submit the submitter keys file" || bad "S1 sshd override missing for pneuma-submit"
eff_root="$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null)"
grep -q "^authorizedkeysfile /etc/ssh/authorized_keys/" <<<"$eff_root" \
  && bad "S1 override LEAKS to user root" || pass "S1 override does not reach user root (scope)"
eff_dt="$(sshd -T -C user=dean-test,host=localhost,addr=127.0.0.1 2>/dev/null)"
grep -q "^authorizedkeysfile /etc/ssh/authorized_keys/" <<<"$eff_dt" \
  && bad "S1 override LEAKS to dean-test" || pass "S1 override does not reach other users (scope)"
[ -z "$(ls -A "$s" | grep '^work\.')" ] && pass "S1 work dir removed on success" || bad "S1 work dir left behind"
rm -rf "$s"

# real sudo through the installed rule: the entry reaches the runner as root; sudo refuses other commands
rm -f /out/runner.txt /out/entry.err
su pneuma-submit -s /bin/bash -c "SSH_ORIGINAL_COMMAND=status $ENTRY --submitter dean-devbox" >/dev/null 2>/out/entry.err
grep -q '^uid=0 sudo_user=pneuma-submit args=status --submitter dean-devbox$' /out/runner.txt 2>/dev/null \
  && pass "S1 entry reaches the runner as root via real sudo (SUDO_USER=pneuma-submit)" \
  || bad "S1 entry->runner: $(cat /out/runner.txt 2>/dev/null) $(cat /out/entry.err)"
if su pneuma-submit -s /bin/bash -c "sudo -n /bin/cat /etc/shadow" >/dev/null 2>&1; then bad "S1 sudo ESCALATED to cat /etc/shadow"; else pass "S1 sudo refuses commands outside the three verbs"; fi

# ------------------------------------------------------------------ refusals: live state must stay exactly OLD
refuse_case() { # name, setup-fn, [PATH prefix]
  local name="$1" setup="$2" pre="${3:-}"
  seed_old; s="$(new_stage)"; $setup "$s"
  run_install "$s" "$pre"; rc=$?
  if [ "$rc" != 0 ] && old_intact; then pass "$name refused (rc $rc), live state unchanged"
  else bad "$name: rc=$rc old_intact=$(old_intact && echo y || echo n) $(tail -2 "$LOG")"; fi
  rm -rf "$s"
}
keys_ok() { printf 'dean-devbox %s submit-test\n' "$KEY1" > "$1/gate-submit-keys"; }
s2() { printf 'ci-lane %s submit-test\n' "$KEY2" > "$1/gate-submit-keys"; mv /etc/pneuma-gate/from.conf /etc/pneuma-gate/from.conf.away; }
s2_restore() { mv /etc/pneuma-gate/from.conf.away /etc/pneuma-gate/from.conf 2>/dev/null || true; }
refuse_case "S2 from.conf missing (a from-name is used)" s2
s2_restore
s3() { printf 'ci-lane %s submit-test\n' "$KEY2" > "$1/gate-submit-keys"; chmod 0644 /etc/pneuma-gate/from.conf; }
refuse_case "S3 from.conf mode 0644" s3
chmod 0600 /etc/pneuma-gate/from.conf
s4() { printf 'ci-lane %s submit-test\n' "$KEY2" > "$1/gate-submit-keys"; chown daemon /etc/pneuma-gate/from.conf; }
refuse_case "S4 from.conf not root-owned" s4
chown root:root /etc/pneuma-gate/from.conf; chmod 0600 /etc/pneuma-gate/from.conf
s5() { printf 'dean-devbox %s,command=/bin/sh\n' "$KEY1" > "$1/gate-submit-keys"; }
refuse_case "S5 key line with an option injected into the key field" s5
s6() { printf '# only comments\n\n' > "$1/gate-submit-keys"; }
refuse_case "S6 empty key list (would empty the live keys)" s6
s7() { keys_ok "$1"; }
refuse_case "S7 candidate sudoers fails visudo -cf" s7 /shim/visudo-cf-fail
s8() { keys_ok "$1"; }
refuse_case "S8 live sudoers check fails after the writes (rollback)" s8 /shim/visudo-live-fail
s9() { keys_ok "$1"; }
refuse_case "S9 sshd reload fails after the writes (rollback)" s9 /shim/reload-fail

# S10: rollback when the live config did NOT exist before: nothing may be left behind
remove_all; s="$(new_stage)"; keys_ok "$s"
PATH=/shim/visudo-live-fail:$PATH bash "$s/pneuma-submit-install.sh" "$s" >"$LOG" 2>&1; rc=$?
if [ "$rc" != 0 ] && absent_all && ! ls -A /etc/ssh/authorized_keys /etc/sudoers.d /etc/ssh/sshd_config.d /usr/local/bin | grep -q '^\.'; then
  pass "S10 rollback with no prior config removes everything it wrote (rc $rc)"
else bad "S10 rollback left files: $(ls -A "$ENTRY" "$KEYS" "$DROPIN" "$SUDOERS" 2>/dev/null)"; fi
rm -rf "$s"

# S11: a staging dir that is not root 0700 is refused (someone else can write into it)
seed_old; s="$(new_stage)"; keys_ok "$s"; chmod 0755 "$s"
run_install "$s"; rc=$?
if [ "$rc" != 0 ] && old_intact; then pass "S11 staging dir not 0700 refused, live state unchanged"; else bad "S11 rc=$rc"; fi
rm -rf "$s"

# S12: symlinks planted at the old predictable temp names must not be followed or written through
echo VICTIM > /root/victim.txt
ln -sf /root/victim.txt /tmp/pneuma-submit-authorized.new
ln -sf /root/victim.txt /tmp/pneuma-gate-entry.new
ln -sf /root/victim.txt /tmp/pneuma-submit.sudoers
seed_old; s="$(new_stage)"; printf 'dean-devbox %s submit-test\n' "$KEY1" > "$s/gate-submit-keys"
run_install "$s"; rc=$?
if [ "$(cat /root/victim.txt)" = VICTIM ] && [ "$rc" = 0 ]; then pass "S12 planted symlinks at the old /tmp names are not written through"; else bad "S12 victim=$(cat /root/victim.txt) rc=$rc"; fi
rm -f /tmp/pneuma-submit-authorized.new /tmp/pneuma-gate-entry.new /tmp/pneuma-submit.sudoers; rm -rf "$s"

# S13: from= is MANDATORY: a key line with no from-name is refused (live state unchanged)
s13() { printf 'dean-devbox %s\n' "$KEY1" > "$1/gate-submit-keys"; }
refuse_case "S13 key line without a from-name (from= mandatory)" s13

# S14: the from.conf value must be an address/CIDR from the allowlist: a quote, comma, space or hostname is refused
for bad in 'submit-test "10.0.0.1"' 'submit-test 10.0.0.1,10.0.0.2' 'submit-test 10.0.0.1 extra' 'submit-test host.example' 'submit-test 10.0.0.256' 'submit-test 10.0.0.1/33' 'submit-test 0.0.0.0/0' 'submit-test ::/0' 'submit-test 10.0.0.0/8' 'submit-test 2001:db8::/31'; do
  printf '%s\n' "$bad" > /etc/pneuma-gate/from.conf; chmod 0600 /etc/pneuma-gate/from.conf
  s14() { printf 'ci-lane %s submit-test\n' "$KEY2" > "$1/gate-submit-keys"; }
  refuse_case "S14 from.conf value refused: $(printf '%s' "$bad" | tr -c '[:print:]' '?')" s14
done

# S15: IPv6 and CIDR addresses are accepted (installs, rc 0, and the rendered key line carries them)
for good in '2001:db8::1' '10.1.0.0/16' '2001:db8::/32'; do
  printf 'submit-test %s\n' "$good" > /etc/pneuma-gate/from.conf; chmod 0600 /etc/pneuma-gate/from.conf
  seed_old; s="$(new_stage)"; printf 'ci-lane %s submit-test\n' "$KEY2" > "$s/gate-submit-keys"
  run_install "$s"; rc=$?
  if [ "$rc" = 0 ] && grep -qF "from=\"$good\"" "$KEYS"; then pass "S15 from.conf address $good accepted and rendered"
  else bad "S15 $good rc=$rc $(tail -1 "$LOG")"; fi
  rm -rf "$s"
done
printf 'submit-test 10.0.0.7\n' > /etc/pneuma-gate/from.conf; chmod 0600 /etc/pneuma-gate/from.conf

# S16: a restore that itself fails keeps the saved copies (the only record of the previous state), says where
# they are, and fails loudly. A mv shim fails every rename onto the keys file: the forward install fails, and so
# does the restore of the keys file.
mkdir -p /shim/mv-fail-keys
cat > /shim/mv-fail-keys/mv <<'S'
#!/usr/bin/env bash
for a; do last="$a"; done
[ "$last" = /etc/ssh/authorized_keys/pneuma-submit ] && exit 1
exec /bin/mv "$@"
S
chmod +x /shim/mv-fail-keys/mv
seed_old; s="$(new_stage)"; keys_ok "$s"
run_install "$s" /shim/mv-fail-keys; rc=$?
kept="$(sed -n 's/.*Saved copies kept at \([^ ]*\).*/\1/p' "$LOG" | head -1)"
if [ "$rc" != 0 ] && grep -q 'RESTORE FAILED for /etc/ssh/authorized_keys/pneuma-submit' "$LOG" \
   && grep -q 'NOT fully restored' "$LOG" && [ -n "$kept" ] && [ -d "$kept" ] && [ "$(cat "$kept/keys" 2>/dev/null)" = OLD-KEYS ] \
   && [ "$(stat -c '%U:%a' "$kept")" = root:700 ]; then
  pass "S16 a failed restore persists the saved copies in the root-only rescue dir ($kept), says so loudly, rc $rc"
else bad "S16 rc=$rc kept='$kept' ls=$(ls -la "$kept" 2>&1 | tr '\n' ' ') keys=$(cat "$kept/keys" 2>&1) mode=$(stat -c '%U:%a' "$kept" 2>&1) log: $(tail -3 "$LOG")"; fi
rm -rf "$s" /var/lib/pneuma-gate-install-rescue

# S17: the submit account is created by the installer when it is missing (the entry cannot be reached without it)
userdel -r pneuma-submit >/dev/null 2>&1 || true
seed_old; s="$(new_stage)"; printf 'dean-devbox %s submit-test\n' "$KEY1" > "$s/gate-submit-keys"
run_install "$s"; rc=$?
if [ "$rc" = 0 ] && id pneuma-submit >/dev/null 2>&1 && [ "$(getent passwd pneuma-submit | cut -d: -f7)" = /bin/bash ]; then
  pass "S17 the installer creates the missing pneuma-submit account (rc 0)"
else bad "S17 rc=$rc account: $(id pneuma-submit 2>&1) log: $(tail -2 "$LOG")"; fi
rm -rf "$s"

# S18: an existing account with a USABLE password is refused before any live change
echo 'pneuma-submit:not-a-real-password' | chpasswd
seed_old; s="$(new_stage)"; printf 'dean-devbox %s submit-test\n' "$KEY1" > "$s/gate-submit-keys"
run_install "$s"; rc=$?
if [ "$rc" != 0 ] && old_intact; then pass "S18 an existing account with a usable password is refused, live state unchanged (rc $rc)"
else bad "S18 rc=$rc old_intact=$(old_intact && echo y || echo n) log: $(tail -1 "$LOG")"; fi
rm -rf "$s"

# S19: a locked account (password locked) is accepted; the home is then root-owned
passwd -l pneuma-submit >/dev/null 2>&1
seed_old; s="$(new_stage)"; printf 'dean-devbox %s submit-test\n' "$KEY1" > "$s/gate-submit-keys"
run_install "$s"; rc=$?
submit_home="$(getent passwd pneuma-submit | cut -d: -f6)"
if [ "$rc" = 0 ] && [ "$(stat -c %U "$submit_home")" = root ]; then pass "S19 a locked account is accepted and its home is root-owned (rc 0)"
else bad "S19 rc=$rc home=$(stat -c %U "$submit_home" 2>&1) log: $(tail -1 "$LOG")"; fi
rm -rf "$s"

# S20: an account with an EXTRA group (sudo) is refused before any live change
usermod -aG sudo pneuma-submit
seed_old; s="$(new_stage)"; printf 'dean-devbox %s submit-test\n' "$KEY1" > "$s/gate-submit-keys"
run_install "$s"; rc=$?
if [ "$rc" != 0 ] && old_intact; then pass "S20 an account with an extra group is refused, live state unchanged (rc $rc)"
else bad "S20 rc=$rc log: $(tail -1 "$LOG")"; fi
rm -rf "$s"
gpasswd -d pneuma-submit sudo >/dev/null 2>&1

# ------------------------------------------------------------------ report
if [ "$fails" = 0 ]; then echo "submit-install: all scenarios passed"; exit 0; fi
echo "submit-install: $fails scenario(s) FAILED"; exit 1
