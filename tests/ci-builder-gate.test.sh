#!/usr/bin/env bash
# tests/ci-builder-gate.test.sh — the installer's client side (ci-builder-gate.sh), with ssh and rsync shimmed.
# Proves: the host's staging path is validated before anything is copied; every upload goes under that root-owned
# staging dir (never a /tmp name); the staging dir is removed on exit, success or failure; a failed submit-path
# install stops the run before the runner and profile steps.
#   bash tests/ci-builder-gate.test.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

mkdir -p "$work/shim" "$work/dest"
LOG="$work/calls.log"
cat > "$work/shim/ssh" <<'S'
#!/usr/bin/env bash
echo "ssh $*" >> "$LOG_FILE"
case "$*" in
  *hostname*) echo "${SHIM_HOST:-fakehost}"; { [ -t 0 ] || cat >/dev/null; }; exit 0;;
  *mktemp\ -d*) echo "${SHIM_STAGE:-/var/lib/pneuma-gate-install/stage.abc123}"; { [ -t 0 ] || cat >/dev/null; }; exit 0;;
  *pneuma-submit-install.sh*) { [ -t 0 ] || cat >/dev/null; }; [ -n "${SHIM_INSTALL_FAIL:-}" ] && exit 1; exit 0;;
  *) { [ -t 0 ] || cat >/dev/null; }; exit 0;;
esac
S
cat > "$work/shim/rsync" <<'S'
#!/usr/bin/env bash
echo "rsync $*" >> "$LOG_FILE"
exit 0
S
chmod +x "$work/shim"/*

run() { # env overrides, then args
  : > "$LOG"
  env PATH="$work/shim:$PATH" LOG_FILE="$LOG" PNEUMA_GATE_HOST=fakehost PNEUMA_GATE_EXPECT_HOST=fakehost \
      PNEUMA_GATE_CLIENT_DEST="$work/dest" "$@" bash "$REPO/ci-builder-gate.sh" --host-only >"$work/out" 2>&1
}

# 1. a staging path the host did not produce in the expected form is refused before any upload
run SHIM_STAGE=/tmp/evil; rc=$?
if [ "$rc" != 0 ] && ! grep -q '^rsync' "$LOG"; then pass "a staging path outside the root stage pattern is refused before any upload"
else bad "unexpected staging path accepted (rc $rc): $(cat "$LOG")"; fi

# 2. happy path: every upload goes under the root staging dir, the installer runs from it, and the dir is removed
run; rc=$?
stage=/var/lib/pneuma-gate-install/stage.abc123
# the destination is the last field of each rsync line (the local source may live under /tmp in a worktree)
dests="$(grep '^rsync' "$LOG" | awk '{print $NF}')"
if [ "$rc" = 0 ] && [ -n "$dests" ] && ! grep -q '/tmp/' <<<"$dests" && ! grep -qv "^fakehost:$stage" <<<"$dests"; then
  pass "every upload lands under the root-owned staging dir, none under /tmp"
else bad "uploads (rc $rc): $dests"; fi
grep -q "pneuma-submit-install.sh '$stage/pneuma-submit-install.sh' '$stage'\|bash '$stage/pneuma-submit-install.sh' '$stage'" "$LOG" \
  && pass "the submit-path installer runs from the staging dir with that dir as its argument" \
  || bad "installer invocation: $(grep install "$LOG")"
grep -q "rm -rf -- $stage" "$LOG" && pass "the staging dir is removed on exit (success)" || bad "no staging cleanup on success"

# 3. a failed submit-path install stops the run before the runner/profile steps, and still cleans up
run SHIM_INSTALL_FAIL=1; rc=$?
if [ "$rc" != 0 ] && ! grep -q 'bash -s' "$LOG" && grep -q "rm -rf -- $stage" "$LOG"; then
  pass "a failed submit-path install stops the run and still removes the staging dir"
else bad "failure path (rc $rc): $(cat "$LOG")"; fi

# 4. no predictable /tmp names in the install scripts (mktemp in a root-owned dir or beside the target only)
if ! grep -n '/tmp/pneuma' "$REPO/ci-builder-gate.sh" "$REPO/host/pneuma-submit-install.sh" >/dev/null; then
  pass "no predictable /tmp/pneuma names in the install scripts"
else bad "predictable /tmp names: $(grep -n '/tmp/pneuma' "$REPO/ci-builder-gate.sh" "$REPO/host/pneuma-submit-install.sh")"; fi

if [ "$fails" = 0 ]; then echo "ci-builder-gate: all checks passed"; exit 0; fi
echo "ci-builder-gate: $fails check(s) FAILED"; exit 1
