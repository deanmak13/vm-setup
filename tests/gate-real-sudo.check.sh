#!/usr/bin/env bash
# tests/gate-real-sudo.check.sh — the sudo matrix for the submit path, with the REAL sudo.
#
# The rule under test is not copied here: it is rendered by the installer itself
# (host/pneuma-submit-install.sh --render-sudoers), so this test and the installed file cannot drift.
# A throwaway container (--rm, no published ports) runs the real sudo as pneuma-submit against a runner
# stand-in that exits 0 and is only reached when sudo allows the call.
#
# Matrix: the three verbs with their arguments must be ALLOWED; janitor, warm-env, unit, a bare run, a bare
# status, a bare have, the bare runner path with no verb, and /bin/cat must be REFUSED.
# Mutation proof: the rule is then widened to the bare runner path, and the matrix must report violations.
# A widened rule that the matrix does NOT flag would make this test a pass for a broken rule, so the test
# fails unless the widened rule turns the matrix red.
#
#   bash tests/gate-real-sudo.check.sh          (needs docker)
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" != "--inside" ]; then
  command -v docker >/dev/null 2>&1 || { echo "FAIL no docker here: cannot run the real sudo"; exit 1; }
  image="${PNEUMA_TEST_IMAGE:-ubuntu:24.04}"
  timeout 900 docker run --rm -v "$REPO:/src:ro" "$image" bash /src/tests/gate-real-sudo.check.sh --inside
  exit $?
fi

# ------------------------------------------------------------------ inside the container
RUNNER=/usr/local/bin/pneuma-gate-runner
SUDOERS=/etc/sudoers.d/pneuma-submit
fails=0
pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq sudo util-linux >/dev/null 2>&1 || { echo "FAIL apt install"; exit 1; }
id pneuma-submit >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash pneuma-submit
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNNER"; chmod 0755 "$RUNNER"
install -m 0755 /src/bin/pneuma-gate-entry /usr/local/bin/pneuma-gate-entry

# the rule, exactly as the installer renders it
bash /src/host/pneuma-submit-install.sh --render-sudoers "$SUDOERS" || { echo "FAIL --render-sudoers"; exit 1; }
chmod 0440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null 2>&1 || { echo "FAIL rendered rule does not validate"; exit 1; }
RENDERED="$(cat "$SUDOERS")"

# run as pneuma-submit through the real sudo; allowed = sudo ran the stand-in (exit 0), refused = sudo said no
as_submit() { runuser -u pneuma-submit -- sudo -n -- "$RUNNER" "$@" >/dev/null 2>&1; }
as_submit_cmd() { runuser -u pneuma-submit -- sudo -n -- "$@" >/dev/null 2>&1; }

ALLOW=(
  "status --submitter dean-devbox"
  "have --submitter dean-devbox"
  "run --submitter dean-devbox"
)
REFUSE=(
  "janitor"
  "janitor --submitter dean-devbox"
  "warm-env --submitter dean-devbox"
  "unit --submitter dean-devbox"
  "run"
  "status"
  "have"
  "__BARE_RUNNER__"
)

# prints the number of matrix violations (an allowed call refused, or a refused call allowed)
matrix() {
  local v=0 a r
  for a in "${ALLOW[@]}"; do
    # shellcheck disable=SC2086
    as_submit $a || { echo "  violation: allowed call refused: '$a'" >&2; v=$((v+1)); }
  done
  for r in "${REFUSE[@]}"; do
    if [ "$r" = __BARE_RUNNER__ ]; then
      if as_submit; then echo "  violation: bare runner path allowed" >&2; v=$((v+1)); fi
      continue
    fi
    # shellcheck disable=SC2086
    if as_submit $r; then echo "  violation: refused call allowed: '${r:-<bare runner path>}'" >&2; v=$((v+1)); fi
  done
  # /bin/cat is never reachable through this rule
  if as_submit_cmd /bin/cat /etc/shadow; then echo "  violation: /bin/cat allowed" >&2; v=$((v+1)); fi
  echo "$v"
}

real_v="$(matrix 2>/tmp/matrix-real.err)"
if [ "$real_v" = 0 ]; then pass "real rule: every allowed call runs, every refused call is refused, /bin/cat refused"
else bad "real rule: $real_v violation(s): $(cat /tmp/matrix-real.err)"; fi

# the entry path through the same rule: it reaches the runner as root with SUDO_USER set
rm -f /tmp/entry-check.out
cat > "$RUNNER" <<'STUB'
#!/usr/bin/env bash
echo "uid=$(id -u) sudo_user=${SUDO_USER:-none} args=$*" > /tmp/entry-check.out
STUB
runuser -u pneuma-submit -- env SSH_ORIGINAL_COMMAND=status /usr/local/bin/pneuma-gate-entry --submitter dean-devbox >/dev/null 2>&1
grep -q '^uid=0 sudo_user=pneuma-submit args=status --submitter dean-devbox$' /tmp/entry-check.out 2>/dev/null \
  && pass "entry reaches the runner as root via the real sudo (SUDO_USER=pneuma-submit)" \
  || bad "entry->runner: $(cat /tmp/entry-check.out 2>/dev/null)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNNER"; chmod 0755 "$RUNNER"

# mutation: widen the rule to the bare runner path. The matrix MUST go red, or the test proves nothing.
printf 'Defaults!%s env_reset\npneuma-submit ALL=(root) NOPASSWD: %s\n' "$RUNNER" "$RUNNER" > "$SUDOERS"
chmod 0440 "$SUDOERS"
mut_v="$(matrix 2>/dev/null)"
if [ "$mut_v" -gt 0 ]; then pass "mutant (bare runner path) turns the matrix red ($mut_v violation(s))"
else bad "mutant (bare runner path) was NOT detected: the matrix is blind to a widened rule"; fi
printf '%s\n' "$RENDERED" > "$SUDOERS"; chmod 0440 "$SUDOERS"

if [ "$fails" = 0 ]; then echo "gate-real-sudo: all checks passed"; exit 0; fi
echo "gate-real-sudo: $fails check(s) FAILED"; exit 1
