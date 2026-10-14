#!/usr/bin/env bash
# gate-real-sudo.check.sh — the one REAL-sudo test of the submit privilege path (#20).
#
# A throwaway container (--rm, no published ports, so nothing listens beyond the container's own
# loopback) installs the real sudo, the entry, the sudoers rule the installer renders, and a runner
# STAND-IN that records who it runs as. Then pneuma-submit goes through the entry and must:
#   (1) reach the runner as root, with SUDO_USER=pneuma-submit (the real sudo, no stand-in);
#   (2) be refused any other sudo command (the rule is exactly the three verbs, nothing else).
# The runner's own refusal of a foreign SUDO_USER is covered by the runner suite, not here.
# Not part of tests/coverage.sh: it needs docker. Run it on a host with docker:
#   bash tests/gate-real-sudo.check.sh
set -uo pipefail
fail=0
DESC=""
check() { if "$@"; then echo "ok   $DESC"; else echo "FAIL $DESC"; fail=1; fi; }
command -v docker >/dev/null 2>&1 || { echo "FAIL no docker here: this check cannot prove the sudo path"; exit 1; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${PNEUMA_TEST_IMAGE:-ubuntu:24.04}"
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT

docker run --rm -v "$repo:/src:ro" -v "$out:/out" "$image" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null && apt-get install -y -qq sudo >/dev/null
  useradd --system --create-home --shell /bin/bash pneuma-submit
  install -m 0755 /src/bin/pneuma-gate-entry /usr/local/bin/pneuma-gate-entry
  # the runner stand-in: records its uid and SUDO_USER, and what it was given
  cat > /usr/local/bin/pneuma-gate-runner <<STUB
#!/usr/bin/env bash
echo "uid=\$(id -u) sudo_user=\${SUDO_USER:-none} args=\$*" > /out/runner.txt
STUB
  chmod 0755 /usr/local/bin/pneuma-gate-runner
  # the sudoers rule exactly as ci-builder-gate.sh renders it
  printf "Defaults!/usr/local/bin/pneuma-gate-runner env_reset\npneuma-submit ALL=(root) NOPASSWD: /usr/local/bin/pneuma-gate-runner status *, /usr/local/bin/pneuma-gate-runner have *, /usr/local/bin/pneuma-gate-runner run *\n" > /etc/sudoers.d/pneuma-submit
  chmod 0440 /etc/sudoers.d/pneuma-submit
  visudo -cf /etc/sudoers.d/pneuma-submit >/dev/null
  # (1) the entry, as pneuma-submit, reaches the runner as root through the real sudo
  su pneuma-submit -s /bin/bash -c "SSH_ORIGINAL_COMMAND=\"status\" /usr/local/bin/pneuma-gate-entry --submitter dean-devbox" >/out/entry.stdout 2>/out/entry.stderr; echo "entry-exit=\$?" >> /out/entry.stderr
  # (2) any other command is refused by sudo
  if su pneuma-submit -s /bin/bash -c "sudo -n /bin/cat /etc/shadow" >/dev/null 2>&1; then echo ESCALATED > /out/other.txt; else echo refused > /out/other.txt; fi
  # (3) the runner refuses a sudo caller other than pneuma-submit
' || { echo "FAIL the container run itself failed"; exit 1; }

DESC="(1) the entry reaches the runner as root through the real sudo, with SUDO_USER=pneuma-submit"
check bash -c 'grep -q "uid=0 sudo_user=pneuma-submit args=status --submitter dean-devbox" "$1/runner.txt" 2>/dev/null' _ "$out" || { echo "--- entry stderr:"; cat "$out/entry.stderr" 2>/dev/null; }
DESC="(2) sudo refuses any command outside the three verbs"
check bash -c 'test "$(cat "$1/other.txt" 2>/dev/null)" = refused' _ "$out"
exit "$fail"
