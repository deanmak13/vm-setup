#!/usr/bin/env bash
# tests/ci-builder-gate.check.sh — the CALLER (ci-builder-gate.sh) end to end, in a throwaway container.
#
# Unlike the shim-only test (ci-builder-gate.test.sh), the installer and the profiles block really run: the
# ssh shim executes the host side HERE, as root, against the real paths, and rsync is real. Proves:
#   1. a failed submit-path restore keeps its saved copies in the persistent root-only rescue dir, and the
#      caller's own staging cleanup does not remove them;
#   2. a failed profiles swap leaves the previous profiles live, prints why, and leaves no stale version dir
#      or temp link behind;
#   3. a clean run swaps the profiles to the new version and keeps only the new version and the previous one.
#
# Needs docker. The host side starts ONE throwaway container (--rm, no published ports).
#   bash tests/ci-builder-gate.check.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" != "--inside" ]; then
  command -v docker >/dev/null 2>&1 || { echo "FAIL no docker here: cannot run the caller against real paths"; exit 1; }
  image="${PNEUMA_TEST_IMAGE:-ubuntu:24.04}"
  timeout 1200 docker run --rm -v "$REPO:/src:ro" "$image" bash /src/tests/ci-builder-gate.check.sh --inside
  exit $?
fi

# ------------------------------------------------------------------ inside the container
ROOT=/usr/local/lib/pneuma-gate
PROFILES="$ROOT/profiles"
RESCUE_ROOT=/var/lib/pneuma-gate-install-rescue
fails=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }
LOG=/tmp/caller.log

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq sudo openssh-server rsync >/dev/null 2>&1 || { echo "FAIL apt install"; exit 1; }
ssh-keygen -A >/dev/null 2>&1; mkdir -p /run/sshd /etc/pneuma-gate
grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config || { echo "FAIL sshd_config does not Include sshd_config.d"; exit 1; }
printf 'devbox 10.1.0.7\n' > /etc/pneuma-gate/from.conf; chmod 0600 /etc/pneuma-gate/from.conf
# no systemd in the container: a systemctl that succeeds, so the submit path reaches the reload step
printf '#!/usr/bin/env bash\nexit 0\n' > /usr/local/bin/systemctl; chmod 0755 /usr/local/bin/systemctl

# shims. base: ssh runs the host side locally as root; rsync is real but strips the host prefix.
mkdir -p /shim/base /shim/fail-link /shim/fail-keys
cat > /shim/base/ssh <<'S'
#!/usr/bin/env bash
while [ "${1:-}" = -o ]; do shift 2; done
host="$1"; shift
[ "$host" = fakehost ] || { echo "ssh stand-in: unknown host $host" >&2; exit 255; }
[ $# -eq 0 ] && exit 0
[ "$1" = hostname ] && { echo fakehost; exit 0; }
exec bash -c "$*"
S
cat > /shim/base/rsync <<'S'
#!/usr/bin/env bash
args=(); for a in "$@"; do args+=("${a#fakehost:}"); done
exec /usr/bin/rsync "${args[@]}"
S
# fail-link: the profiles swap (a rename of the new link onto the live profiles path) fails
cat > /shim/fail-link/mv <<'S'
#!/usr/bin/env bash
src="${*: -2:1}"; dst="${*: -1}"
case "$src" in *.profiles-link.*) [ "$dst" = /usr/local/lib/pneuma-gate/profiles ] && exit 1;; esac
exec /bin/mv "$@"
S
# fail-keys: any rename onto the submitter keys file fails (forward install AND its restore)
cat > /shim/fail-keys/mv <<'S'
#!/usr/bin/env bash
last="${*: -1}"
[ "$last" = /etc/ssh/authorized_keys/pneuma-submit ] && exit 1
exec /bin/mv "$@"
S
chmod +x /shim/base/* /shim/fail-link/mv /shim/fail-keys/mv

run_caller() { # PATH prefix (may be empty); output to $LOG
  local pre="$1"
  PATH="${pre:+$pre:}/shim/base:$PATH" PNEUMA_GATE_HOST=fakehost PNEUMA_GATE_EXPECT_HOST=fakehost \
    PNEUMA_GATE_CLIENT_DEST=/tmp/client-dest bash /src/ci-builder-gate.sh --host-only >"$LOG" 2>&1
}
seed_submit_old() {
  mkdir -p /etc/ssh/authorized_keys /etc/sudoers.d /etc/ssh/sshd_config.d /usr/local/bin
  printf 'OLD-ENTRY\n' > /usr/local/bin/pneuma-gate-entry; chmod 0755 /usr/local/bin/pneuma-gate-entry
  printf 'OLD-KEYS\n' > /etc/ssh/authorized_keys/pneuma-submit; chmod 0644 /etc/ssh/authorized_keys/pneuma-submit
  printf 'OLD-DROPIN\n' > /etc/ssh/sshd_config.d/50-pneuma-submit.conf; chmod 0644 /etc/ssh/sshd_config.d/50-pneuma-submit.conf
  printf 'OLD-SUDOERS\n' > /etc/sudoers.d/pneuma-submit; chmod 0440 /etc/sudoers.d/pneuma-submit
}
seed_profiles_old() { # the previous profiles: a versioned dir behind the live symlink
  rm -rf "$ROOT"; mkdir -p "$ROOT/profiles.d/v.OLD"
  printf 'OLD-PROFILE\n' > "$ROOT/profiles.d/v.OLD/marker.txt"
  ln -s profiles.d/v.OLD "$PROFILES"
}
stage_leftovers() { ls -d /var/lib/pneuma-gate-install/stage.* 2>/dev/null; }

# ------------------------------------------------------------------ 1. rescue through the caller
rm -rf "$RESCUE_ROOT" /var/lib/pneuma-gate-install; seed_submit_old
run_caller /shim/fail-keys; rc=$?
rescue="$(ls -d "$RESCUE_ROOT"/*/ 2>/dev/null | head -1)"
if [ "$rc" != 0 ] && grep -q "Saved copies kept at $RESCUE_ROOT/" "$LOG" && [ -n "$rescue" ] \
   && [ "$(stat -c '%U:%a' "$RESCUE_ROOT")" = root:700 ] && [ "$(stat -c '%U:%a' "$rescue")" = root:700 ] \
   && [ "$(cat "$rescue/keys" 2>/dev/null)" = OLD-KEYS ]; then
  pass "1 failed restore: saved copies persist in the root-only rescue dir, through the caller (rc $rc)"
else bad "1 rescue rc=$rc rescue='$rescue' log: $(tail -3 "$LOG")"; fi
if [ -z "$(stage_leftovers)" ]; then pass "1 the caller's staging dir is still removed on exit"
else bad "1 staging dir left: $(stage_leftovers)"; fi
# the rescue copy is not inside the staging dir, so the caller's rm of the staging dir cannot reach it
[ -f "$rescue/keys" ] && pass "1 rescue copy survives the caller's cleanup" || bad "1 rescue copy lost"

# ------------------------------------------------------------------ 2. a failed profiles swap leaves the old profiles live
rm -rf "$RESCUE_ROOT"; seed_submit_old; seed_profiles_old
run_caller /shim/fail-link; rc=$?
if [ "$rc" != 0 ] && grep -q 'profiles swap failed; the previous profiles remain live' "$LOG" \
   && [ "$(readlink "$PROFILES")" = profiles.d/v.OLD ] && [ "$(cat "$PROFILES/marker.txt" 2>/dev/null)" = OLD-PROFILE ]; then
  pass "2 failed swap: previous profiles still live, message printed (rc $rc)"
else bad "2 swap rc=$rc link=$(readlink "$PROFILES") log: $(tail -3 "$LOG")"; fi
if [ -z "$(ls -A "$ROOT" | grep '^\.profiles-link')" ] && [ "$(ls "$ROOT/profiles.d" | tr '\n' ' ')" = "v.OLD " ]; then
  pass "2 no stale temp link and no stale new version dir remains"
else bad "2 leftovers: root=$(ls -A "$ROOT") profiles.d=$(ls "$ROOT/profiles.d")"; fi

# ------------------------------------------------------------------ 3. a clean run swaps to the new version
rm -rf "$RESCUE_ROOT"; seed_submit_old; seed_profiles_old
run_caller ""; rc=$?
new="$(readlink "$PROFILES" 2>/dev/null)"
if [ "$new" != profiles.d/v.OLD ] && [ -n "$new" ] && diff -r /src/gate-profiles "$PROFILES" >/dev/null 2>&1; then
  pass "3 clean run: profiles now the new version, identical to gate-profiles (rc $rc)"
else bad "3 new link='$new' rc=$rc diff: $(diff -r /src/gate-profiles "$PROFILES" 2>&1 | head -2)"; fi
kept="$(ls "$ROOT/profiles.d" | sort | tr '\n' ' ')"
if [ "$kept" = "$(basename "$new") v.OLD " ] || [ "$kept" = "v.OLD $(basename "$new") " ]; then
  pass "3 only the new version and the previous one are kept (no stale dirs)"
else bad "3 profiles.d holds: $kept"; fi
if [ -z "$(ls -A "$ROOT" | grep '^\.profiles-link')" ]; then pass "3 no temp link left behind"
else bad "3 temp link left"; fi

# ------------------------------------------------------------------ report
if [ "$fails" = 0 ]; then echo "ci-builder-gate caller: all checks passed"; exit 0; fi
echo "ci-builder-gate caller: $fails check(s) FAILED"; exit 1
