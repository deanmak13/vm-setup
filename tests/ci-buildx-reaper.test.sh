#!/usr/bin/env bash
# tests/ci-buildx-reaper.test.sh — bin/ci-buildx-reaper run against a fake
# `docker` on PATH (no daemon, no host state). The fake records every call so the
# tests can assert exactly what was (and was never) asked of docker.
#
# Run: bash tests/ci-buildx-reaper.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
REAPER="${REAPER:-$REPO_DIR/bin/ci-buildx-reaper}"

fail=0
expect() {
    local verdict=ok
    [[ "$2" == "$3" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %q (expected: %q)\n' "$verdict" "$1" "$3" "$2"
}
expect_contains() {
    local verdict=ok
    grep -qF -- "$2" <<< "$3" || { verdict=FAIL; fail=1; }
    printf '%-4s %s (want substring: %q)\n' "$verdict" "$1" "$2"
}
expect_absent() {
    local verdict=ok
    if grep -qF -- "$2" <<< "$3"; then verdict=FAIL; fail=1; fi
    printf '%-4s %s (must not contain: %q)\n' "$verdict" "$1" "$2"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/mnt"

# Fake docker. FAKE_VOLS: one volume per line. FAKE_REFS: "volume container-id"
# lines (a container referencing that volume, running or stopped). FAKE_RM_FAIL:
# volume name whose removal docker refuses.
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$1 $2" in
    "volume ls")
        cat "$FAKE_VOLS" ;;
    "ps -aq")
        vol=${4#volume=}
        awk -v v="$vol" '$1==v {print $2}' "$FAKE_REFS" ;;
    "volume inspect")
        vol=${@: -1}
        echo "$FAKE_MNT/$vol" ;;
    "volume rm")
        if [[ "$3" == "${FAKE_RM_FAIL:-}" ]]; then
            echo "Error: volume is in use" >&2; exit 1
        fi
        echo "removed $3" ;;
    *) echo "fake docker: unexpected call: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$work/bin/docker"

export PATH="$work/bin:$PATH"
export FAKE_LOG="$work/docker.calls"
export FAKE_VOLS="$work/vols"
export FAKE_REFS="$work/refs"
export FAKE_MNT="$work/mnt"

# Volumes: two orphans of different size, one active builder (registry), one
# referenced by a stopped container, one non-matching name, one whose removal
# docker refuses.
printf '%s\n' \
    buildx_buildkit_builder-orphan-a_state \
    buildx_buildkit_builder-orphan-b_state \
    buildx_buildkit_pneuma-engine-main-v10_state \
    buildx_buildkit_stopped-builder_state \
    buildx_buildkit_refused-builder_state \
    buildx_buildkit_extra_state_x \
    my_unrelated_volume > "$FAKE_VOLS"
printf '%s\n' "buildx_buildkit_stopped-builder_state cafe01" > "$FAKE_REFS"
mkdir -p "$work/mnt/buildx_buildkit_builder-orphan-a_state" "$work/mnt/buildx_buildkit_builder-orphan-b_state" \
         "$work/mnt/buildx_buildkit_refused-builder_state"
head -c 4096 /dev/zero > "$work/mnt/buildx_buildkit_builder-orphan-a_state/blob"
head -c 8192 /dev/zero > "$work/mnt/buildx_buildkit_builder-orphan-b_state/blob"

registry="$work/active-builders.txt"
printf '%s\n' "# comment line" "pneuma-engine-main-v10   # trailing comment" "" > "$registry"

run() { # run <extra args...> — captures stdout+stderr and exit code
    : > "$FAKE_LOG"
    RC=0
    OUT=$(bash "$REAPER" --registry "$registry" --log "$work/reaper.log" "$@" 2>&1) || RC=$?
    CALLS=$(cat "$FAKE_LOG")
}

# 1. Dry run: nothing removed, orphans reported, actives and referenced kept.
unset FAKE_RM_FAIL
run --dry-run --floor-bytes 0
expect "dry-run exit code" 0 "$RC"
expect_absent "dry-run issues no volume rm" "volume rm" "$CALLS"
expect_contains "dry-run reports orphan-a" "would delete buildx_buildkit_builder-orphan-a_state size=4096B" "$(cat "$work/reaper.log")"
expect_contains "dry-run reports orphan-b" "would delete buildx_buildkit_builder-orphan-b_state size=8192B" "$(cat "$work/reaper.log")"
expect_absent "dry-run never names the active builder" "would delete buildx_buildkit_pneuma-engine-main-v10_state" "$(cat "$work/reaper.log")"
expect_absent "dry-run never names the referenced volume" "would delete buildx_buildkit_stopped-builder_state" "$(cat "$work/reaper.log")"

# 2. Real run: exact rm set, logs each deletion with size, never prunes.
run --floor-bytes 0
expect "real run exit code" 0 "$RC"
expect_contains "rm orphan-a" "volume rm buildx_buildkit_builder-orphan-a_state" "$CALLS"
expect_contains "rm orphan-b" "volume rm buildx_buildkit_builder-orphan-b_state" "$CALLS"
expect_absent "never rm the active builder" "volume rm buildx_buildkit_pneuma-engine-main-v10_state" "$CALLS"
expect_absent "never rm a referenced volume" "volume rm buildx_buildkit_stopped-builder_state" "$CALLS"
expect_absent "never rm a non-matching name" "volume rm buildx_buildkit_extra_state_x" "$CALLS"
expect_absent "never rm an unrelated volume" "volume rm my_unrelated_volume" "$CALLS"
expect_absent "never volume prune" "prune" "$CALLS"
expect_contains "deletion logged with size" "deleted buildx_buildkit_builder-orphan-b_state size=8192B" "$(cat "$work/reaper.log")"
expect_contains "summary counts" "deleted=3 kept=2" "$(cat "$work/reaper.log")"

# 3. Refused removal is logged as FAILED and the run continues.
export FAKE_RM_FAIL=buildx_buildkit_refused-builder_state
printf '%s\n' buildx_buildkit_refused-builder_state buildx_buildkit_builder-orphan-b_state > "$FAKE_VOLS"
run --floor-bytes 0
expect "refused removal does not abort" 0 "$RC"
expect_contains "refused removal logged" "FAILED to delete buildx_buildkit_refused-builder_state" "$(cat "$work/reaper.log")"
expect_contains "later orphan still reaped" "volume rm buildx_buildkit_builder-orphan-b_state" "$CALLS"
unset FAKE_RM_FAIL

# 4. Free space still under the floor after the run: exit 3 and an ALERT line.
printf '%s\n' buildx_buildkit_builder-orphan-b_state > "$FAKE_VOLS"
run --floor-bytes 99999999999999999999
expect "under-floor exit code" 3 "$RC"
expect_contains "under-floor alert logged" "ALERT free disk" "$(cat "$work/reaper.log")"

# 5. Dry run never fails on the floor.
run --dry-run --floor-bytes 99999999999999999999
expect "dry-run ignores floor" 0 "$RC"

# 6. Missing registry is a hard failure, never a reap with no allowlist.
RC=0; : > "$FAKE_LOG"
OUT=$(bash "$REAPER" --registry "$work/nope.txt" --log "$work/reaper.log" 2>&1) || RC=$?
expect "missing registry exit code" 1 "$RC"
expect_absent "missing registry issues no rm" "volume rm" "$(cat "$FAKE_LOG")"

echo
if (( fail )); then echo "ci-buildx-reaper tests: FAILED"; exit 1; fi
echo "ci-buildx-reaper tests: all passed"
