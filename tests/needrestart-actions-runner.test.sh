#!/usr/bin/env bash
# tests/needrestart-actions-runner.test.sh — proves needrestart-actions-runner.conf
# does what ci-builder-bootstrap.sh installs it for.
#
# needrestart decides per service with the first matching $nrconf{override_rc}
# regex (tests/needrestart-decide.pl mirrors that loop): a value of 0 skips the
# restart. The conf must therefore match every actions.runner.* unit the
# bootstrap registers (§9 RUNNERS table — svc.sh names units
# actions.runner.<owner>-<repo>.<runner>.service) and nothing else on the host.
# Both sides are checked here, the runner set derived from the bootstrap's own
# table so a new runner is covered without touching this file.
#
# Run: bash tests/needrestart-actions-runner.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
CONF="$REPO_DIR/needrestart-actions-runner.conf"
BOOTSTRAP="$REPO_DIR/ci-builder-bootstrap.sh"
OWNER=$(sed -n 's/^OWNER=\([A-Za-z0-9-]*\)$/\1/p' "$BOOTSTRAP")
[[ -n "$OWNER" ]] || { echo "FAIL OWNER not found in $BOOTSTRAP"; exit 1; }

fail=0
# expect <unit> <restart|skip> <matches> — the verdict needrestart would reach for <unit>.
expect() {
    local got verdict=ok
    got=$(perl "$TESTS_DIR/needrestart-decide.pl" "$CONF" "$1")
    [[ "$got" == "$2 $3" ]] || { verdict=FAIL; fail=1; }
    printf '%-4s %s -> %s (expected: %s %s)\n' "$verdict" "$1" "$got" "$2" "$3"
}
# check <description> <command...> — records a FAIL when the command exits non-zero.
check() {
    local label=$1 verdict=ok
    shift
    "$@" >/dev/null 2>&1 || { verdict=FAIL; fail=1; }
    printf '%-4s %s\n' "$verdict" "$label"
}

check "conf is valid Perl" perl -c "$CONF"

# Every runner unit the bootstrap registers is skipped, by exactly one regex.
# (The range anchors on the table's line prefix, not its heredoc opener: a
# literal opener here is one kcov's parser would wait to see terminated, and
# it instruments nothing past it.)
while read -r repo runner _; do
    expect "actions.runner.${OWNER}-${repo}.${runner}.service" skip 1
done < <(sed -n '/^RUNNERS=/,/^EOF$/p' "$BOOTSTRAP" | sed '1d;$d')

# Everything else on the host keeps needrestart's normal behaviour.
for unit in k3s.service docker.service containerd.service ssh.service dbus.service \
            unattended-upgrades.service cloudflared-access-openbao.service \
            runner-reaper.service runner-reaper.timer ci-disk-janitor.timer \
            github-actions.runner.service; do
    expect "$unit" restart 0
done
# The regex is anchored: a unit that merely contains the runner prefix is not exempt.
expect "x-actions.runner.${OWNER}-pneuma.pneuma-contabo.service" restart 0

# The conf adds its override without replacing the distribution defaults.
check "conf extends \$nrconf{override_rc} instead of assigning the whole hash" \
    perl -ne 'exit 1 if /override_rc}\s*=\s*\{/' "$CONF"

# The bootstrap installs this exact file where needrestart reads conf.d.
check "ci-builder-bootstrap.sh installs needrestart-actions-runner.conf" \
    grep -q 'install -D -m 0644 "\$REPO_DIR/needrestart-actions-runner.conf"' "$BOOTSTRAP"
check "ci-builder-bootstrap.sh targets /etc/needrestart/conf.d/50-actions-runner.conf" \
    grep -q '^    /etc/needrestart/conf.d/50-actions-runner.conf$' "$BOOTSTRAP"

exit "$fail"
