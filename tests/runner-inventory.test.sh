#!/usr/bin/env bash
# tests/runner-inventory.test.sh — the runner inventory in ci-builder-bootstrap.sh
# (§ RUNNERS) is one row per RUNNER with its own labels and directory, and the
# scripts that key off those directories agree with it:
#   - the bootstrap registers each row into /home/ubuntu/actions-runner-<runner-name>
#     with `self-hosted,<labels>`;
#   - runner-reaper's worker_dir/worker_repo (extracted from the installed
#     script's own source, not copied here) resolve a Runner.Worker command
#     line to that directory and to the repo its .runner file registers —
#     no name parsing, so a build-lane runner is attributed correctly;
#   - ci-builder-migration.md describes the same layout.
#
# Run: bash tests/runner-inventory.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
BOOTSTRAP="$REPO_DIR/ci-builder-bootstrap.sh"
REAPER="$REPO_DIR/runner-reaper.sh"
MIGRATION="$REPO_DIR/ci-builder-migration.md"
OWNER=$(sed -n 's/^OWNER=\([A-Za-z0-9-]*\)$/\1/p' "$BOOTSTRAP")
[[ -n "$OWNER" ]] || { echo "FAIL OWNER not found in $BOOTSTRAP"; exit 1; }

fail=0
# check <description> <command...> — records a FAIL when the command exits non-zero.
check() {
    local label=$1 verdict=ok
    shift
    "$@" >/dev/null 2>&1 || { verdict=FAIL; fail=1; }
    printf '%-4s %s\n' "$verdict" "$label"
}
# expect_out <description> <expected> <command...> — the command's stdout must equal <expected>.
expect_out() {
    local label=$1 want=$2 got verdict=ok
    shift 2
    got=$("$@" 2>/dev/null || true)
    [[ "$got" == "$want" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %q (expected: %q)\n' "$verdict" "$label" "$got" "$want"
}
# expect_fail <description> <command...> — the command must exit non-zero and print nothing.
expect_fail() {
    local label=$1 got verdict=ok
    shift
    got=$("$@" 2>/dev/null) && verdict=FAIL
    [[ -z "$got" && "$verdict" == ok ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s\n' "$verdict" "$label"
}

# ── the inventory table ──────────────────────────────────────────────────
rows=$(sed -n "/^RUNNERS=\$(cat <<'EOF'\$/,/^EOF\$/p" "$BOOTSTRAP" | sed '1d;$d')
check "RUNNERS table is present and non-empty" test -n "$rows"
check "every row is exactly '<repo> <runner-name> <labels> <y|n>'" \
    bash -c '! grep -Ev "^[a-z0-9-]+ [a-z0-9-]+ [a-z0-9-]+(,[a-z0-9-]+)* [yn]$" <<< "$1"' _ "$rows"
check "runner names are unique (one directory and one systemd unit each)" \
    bash -c 'test "$(awk "{print \$2}" <<< "$1" | sort | uniq -d | wc -l)" -eq 0' _ "$rows"
check "the labels column never repeats self-hosted (the loop adds it)" \
    bash -c '! awk "{print \$3}" <<< "$1" | grep -q self-hosted' _ "$rows"
check "every runner name is prefixed with its repo (unit names stay readable)" \
    bash -c '! awk "index(\$2, \$1 \"-\") != 1" <<< "$1" | grep -q .' _ "$rows"
check "every label is a lane some workflow can select (ci-builder or ci-builder-build)" \
    bash -c '! awk "{print \$3}" <<< "$1" | tr , "\n" | grep -Evx "ci-builder|ci-builder-build" | grep -q .' _ "$rows"

# ── the registration loop consumes all four columns per runner ───────────
check "loop reads <repo> <runner-name> <labels> <enabled>" \
    grep -qxF 'while read -r repo runner_name labels enabled; do' "$BOOTSTRAP"
check "install directory is actions-runner-<runner-name>" \
    grep -qxF '    dir="/home/ubuntu/actions-runner-${runner_name}"' "$BOOTSTRAP"
check "no per-repo directory with a special-cased -2 suffix remains" \
    bash -c '! grep -q "actions-runner-\${repo}" "$1" && ! grep -q "== \*-2" "$1"' _ "$BOOTSTRAP"
check "config.sh gets self-hosted plus the row's own labels" \
    bash -c 'grep -qx "    runner_labels=\"\$RUNNER_BASE_LABELS,\$labels\"" "$1" && grep -q "^          --labels .\$runner_labels. " "$1" && grep -qx "RUNNER_BASE_LABELS=\"self-hosted\"" "$1"' _ "$BOOTSTRAP"
check "the enabled column decides whether the service is started" \
    grep -qxF '    if [[ "$enabled" == "y" ]]; then' "$BOOTSTRAP"

# ── runner-reaper: worker command line → install dir → repo ──────────────
installed=$(sed -n "/^cat > \/usr\/local\/bin\/runner-reaper <<'SCRIPT'\$/,/^SCRIPT\$/p" "$REAPER" | sed '1d;$d')
check "installed reaper defines worker_dir and worker_repo and uses them in the scan loop" \
    bash -c 'grep -qx "worker_dir() {" <<< "$1" && grep -qx "worker_repo() {" <<< "$1" && grep -qx "    dir=\$(worker_dir \"\$args\") || continue" <<< "$1" && grep -qx "    repo=\$(worker_repo \"\$dir\") || continue" <<< "$1"' _ "$installed"
check "installed reaper no longer parses the repo out of the directory name" \
    bash -c '! grep -q "sed -E .s/(-contabo)" <<< "$1" && ! grep -q "dir=\${args#\*actions-runner-}" <<< "$1"' _ "$installed"
# worker_repo reads $OWNER from the reaper's OWN assignment, not the
# bootstrap's: the two files each hardcode it, so the eval'd function runs
# with the value the installed script would use, and the two must agree —
# a reaper whose OWNER drifts rejects every real runner and goes blind.
reaper_owner=$(sed -n 's/^OWNER=\([A-Za-z0-9-]*\)$/\1/p' <<< "$installed")
check "installed reaper hardcodes the same OWNER as the bootstrap" \
    test "$reaper_owner" = "$OWNER"
eval "$(sed -n '/^worker_dir() {$/,/^}$/p' <<< "$installed")"
eval "$(sed -n '/^worker_repo() {$/,/^}$/p' <<< "$installed")"
OWNER=$reaper_owner

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for r in pneuma-engine-contabo pneuma-engine-contabo-build-1 pneuma-portal-contabo-2; do
    mkdir -p "$work/actions-runner-$r/bin.2.337.0"
done
printf '{"agentName":"pneuma-engine-contabo","gitHubUrl":"https://github.com/%s/pneuma-engine"}\n' "$OWNER" > "$work/actions-runner-pneuma-engine-contabo/.runner"
printf '{"agentName":"pneuma-engine-contabo-build-1","gitHubUrl":"https://github.com/%s/pneuma-engine"}\n' "$OWNER" > "$work/actions-runner-pneuma-engine-contabo-build-1/.runner"
printf '{"agentName":"pneuma-portal-contabo-2","gitHubUrl":"https://github.com/someone-else/pneuma-portal"}\n' > "$work/actions-runner-pneuma-portal-contabo-2/.runner"
mkdir -p "$work/actions-runner-unregistered/bin"

expect_out "worker_dir: versioned bin dir + spawnclient args" "$work/actions-runner-pneuma-engine-contabo-build-1" \
    worker_dir "$work/actions-runner-pneuma-engine-contabo-build-1/bin.2.337.0/Runner.Worker spawnclient 105 108"
expect_out "worker_dir: plain bin dir, no args" "$work/actions-runner-pneuma-engine-contabo" \
    worker_dir "$work/actions-runner-pneuma-engine-contabo/bin/Runner.Worker"
expect_fail "worker_dir: Runner.Listener is not a worker" \
    worker_dir "$work/actions-runner-pneuma-engine-contabo/bin/Runner.Listener run"
expect_fail "worker_dir: a shell whose command line mentions Runner.Worker is not a worker" \
    worker_dir "bash -c 'pgrep -f Runner.Worker; ls $work/actions-runner-pneuma-engine-contabo/bin/Runner.Worker'"
expect_fail "worker_dir: Runner.Worker outside an actions-runner-* directory" \
    worker_dir "/opt/other/bin/Runner.Worker spawnclient 1 2"
expect_fail "worker_dir: a binary merely prefixed Runner.Worker is not the worker" \
    worker_dir "$work/actions-runner-pneuma-engine-contabo/bin/Runner.Worker.orig spawnclient 1 2"

expect_out "worker_repo: gate runner -> its repo" "pneuma-engine" worker_repo "$work/actions-runner-pneuma-engine-contabo"
expect_out "worker_repo: build-lane runner -> the same repo (no suffix parsing)" "pneuma-engine" worker_repo "$work/actions-runner-pneuma-engine-contabo-build-1"
expect_fail "worker_repo: a runner registered to another owner is ignored" worker_repo "$work/actions-runner-pneuma-portal-contabo-2"
expect_fail "worker_repo: no .runner file -> no repo" worker_repo "$work/actions-runner-unregistered"
expect_fail "worker_repo: missing directory -> no repo" worker_repo "$work/actions-runner-gone"

# ── the runbook describes this layout, not a per-repo one ────────────────
check "migration runbook: install directory is actions-runner-<runner-name>" \
    grep -q 'actions-runner-<runner-name>' "$MIGRATION"
check "migration runbook: no stale actions-runner-<repo>[-2] path" \
    bash -c '! grep -q "actions-runner-<repo>" "$1"' _ "$MIGRATION"
check "migration runbook: the inventory table lives in the bootstrap only" \
    bash -c '! grep -q "^| pneuma-engine | pneuma-engine-contabo |" "$1"' _ "$MIGRATION"

exit "$fail"
