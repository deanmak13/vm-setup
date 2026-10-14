#!/usr/bin/env bash
# tests/ci-buildx-reaper-install.test.sh — ci-buildx-reaper.sh (the installer), run
# end to end in a sandbox root via tests/installer-sandbox.lib.sh. Nothing outside
# the temp dir is touched; systemctl and curl are stubbed by the helper.
#
# Run: bash tests/ci-buildx-reaper-install.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
INSTALLER="$REPO_DIR/ci-buildx-reaper.sh"

fail=0
expect() {
    local verdict=ok
    [[ "$2" == "$3" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %q (expected: %q)\n' "$verdict" "$1" "$3" "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# shellcheck source=tests/installer-sandbox.lib.sh
. "$TESTS_DIR/installer-sandbox.lib.sh"

SB="$work/sb"; mkdir -p "$SB/repo"
# The helper copies only bin/ and systemd/ into the sandbox repo; the registry
# lives in buildx-reaper/, so seed it here (the helper keeps an existing dir).
cp -r "$REPO_DIR/buildx-reaper" "$SB/repo/"

inst_rc=0; sandbox_install "$INSTALLER" "$SB" || inst_rc=$?
expect "sandboxed install succeeds" 0 "$inst_rc"
expect "reaper binary installed executable" 755 "$(stat -c %a "$SB/usr/local/bin/ci-buildx-reaper")"
expect "active-builder registry seeded" 1 "$(grep -c '^pneuma-engine-main-v10$' "$SB/etc/ci-buildx-reaper/active-builders.txt" || true)"
expect "default ALERT_REPO written" "ALERT_REPO=vm-setup" "$(cat "$SB/etc/default/ci-buildx-reaper")"
expect "failure-alert program installed" 1 "$(grep -c '^ *ci-buildx-reaper)$' "$SB/usr/local/bin/runner-failure-alert" || true)"

unit="$SB/etc/systemd/system/ci-buildx-reaper.service"
expect "service ExecStart is the reaper" 1 "$(grep -c '^ExecStart=.*/ci-buildx-reaper$' "$unit" || true)"
expect "service declares its OnFailure alert" 1 "$(grep -c '^OnFailure=runner-failure-alert@ci-buildx-reaper.service$' "$unit" || true)"
timer="$SB/etc/systemd/system/ci-buildx-reaper.timer"
expect "timer runs daily" 1 "$(grep -c '^OnCalendar=daily$' "$timer" || true)"
expect "timer catches up after downtime" 1 "$(grep -c '^Persistent=true$' "$timer" || true)"

# Re-running is idempotent and never clobbers an operator-edited registry.
printf '%s\n' "operator-added-builder" >> "$SB/etc/ci-buildx-reaper/active-builders.txt"
first=$(sandbox_digest "$SB")
inst_rc=0; sandbox_install "$INSTALLER" "$SB" || inst_rc=$?
expect "second install succeeds" 0 "$inst_rc"
expect "registry edits survive a re-install" 1 "$(grep -c '^operator-added-builder$' "$SB/etc/ci-buildx-reaper/active-builders.txt" || true)"
expect "re-install leaves every installed file byte-identical" "$first" "$(sandbox_digest "$SB")"
expect "re-install does not append units" 1 "$(grep -c '^\[Service\]$' "$unit" || true)"

inst_rc=0; sandbox_install "$INSTALLER" "$SB" --alert-repo "bad repo" || inst_rc=$?
expect "invalid --alert-repo is refused" 2 "$inst_rc"

echo
if (( fail )); then echo "ci-buildx-reaper install tests: FAILED"; exit 1; fi
echo "ci-buildx-reaper install tests: all passed"
