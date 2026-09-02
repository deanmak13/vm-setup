#!/usr/bin/env bash
# tests/coverage.sh — run every tests/*.test.sh under kcov and leave one merged
# cobertura report at cov/merged/kcov-merged/cobertura.xml with repo-relative
# paths: the report confirm-coverage.sh --diff reads for a vm-setup PR.
#
# The scripts run inside the kcov image (Debian, no jq) with the runtime tools
# the code under test needs installed first — runner-reaper's worker_repo reads
# .runner files with jq, which ci-builder-bootstrap.sh installs on the host.
# kcov's own limit applies: it instruments nothing past a heredoc opener whose
# marker never recurs, which tests/runner-inventory.test.sh scans every test
# file for. This runner is the one script in tests/ the report leaves out: it
# runs on the host, outside the kcov it launches, so kcov could only ever
# report it at zero.
#
# Run: bash tests/coverage.sh            (exit = the tests' own verdict)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${KCOV_IMAGE:-kcov/kcov:latest}"
OUT="$REPO_DIR/cov"

[[ -d "$OUT" ]] && docker run --rm -v "$REPO_DIR:/src" "$IMAGE" rm -rf /src/cov
docker run --rm -v "$REPO_DIR:/src" -w /src -e "HOST_ID=$(id -u):$(id -g)" "$IMAGE" bash -c '
    apt-get -qq update >/dev/null && apt-get -qq install -y jq >/dev/null
    rc=0
    for t in tests/*.test.sh; do
        printf "==> %s\n" "$t"
        kcov --include-path=/src --exclude-pattern=/src/tests/coverage.sh /src/cov "$t" || rc=1
    done
    kcov --merge /src/cov/merged /src/cov/*.test.sh.*
    chown -R "$HOST_ID" /src/cov
    exit "$rc"' || rc=$?
REPORT="$OUT/merged/kcov-merged/cobertura.xml"
sed -i 's#filename="/src/#filename="#' "$REPORT"
printf 'report: %s\n' "$REPORT"
exit "${rc:-0}"
