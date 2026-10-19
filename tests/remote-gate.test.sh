#!/usr/bin/env bash
# tests/remote-gate.test.sh — proves the remote pre-push gate machinery:
#   * bin/pneuma-gate-runner: verdict marker (green/red/no-verdict), per-run
#     isolation + cleanup, disk>=limit refusal, host-identity refusal, tree
#     mismatch refusal, capacity admission (cores / memory / count / load),
#     FIFO queue serialisation, shallow-boundary handling, janitor.
#   * bin/pneuma-remote-gate: ships a commit (not the worktree), trusts only a
#     marker for the exact head+tree from the approved host, maps exits 0/1/75.
#
# The runner runs unprivileged against a temp BASE with a fake profile; `ssh`
# is a stand-in that runs the remote command locally, so both programs are
# exercised end to end without a network.
#
# Run: bash tests/remote-gate.test.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
RUNNER="$REPO_DIR/bin/pneuma-gate-runner"
CLIENT="$REPO_DIR/bin/pneuma-remote-gate"
ENGINE_PROFILE="$REPO_DIR/gate-profiles/engine.sh"
PORTAL_PROFILE="$REPO_DIR/gate-profiles/portal.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
check() {   # check <description> <command...>
  local label=$1 verdict=ok
  shift
  "$@" >/dev/null 2>&1 || { verdict=FAIL; fail=1; }
  printf '%-4s %s\n' "$verdict" "$label"
}
not() { ! "$@"; }
expect_eq() {   # expect_eq <description> <want> <got>
  local verdict=ok
  [[ $2 == "$3" ]] || { verdict=FAIL; fail=1; printf '     want: %q\n     got:  %q\n' "$2" "$3"; }
  printf '%-4s %s\n' "$verdict" "$1"
}

# ── fixtures ─────────────────────────────────────────────────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
src="$work/src/fakerepo"
mkdir -p "$src" "$work/profiles" "$work/bin"
git -C "$src" init -q -b main
printf 'one\n' > "$src/f.txt"
git -C "$src" add f.txt && git -C "$src" commit -qm one
base=$(git -C "$src" rev-parse HEAD)
printf 'two\n' > "$src/f.txt"
git -C "$src" commit -qam two
head=$(git -C "$src" rev-parse HEAD)
tree=$(git -C "$src" rev-parse 'HEAD^{tree}')
printf 'dirty\n' > "$src/untracked-must-not-ship.txt"   # worktree noise the gate must never see
# The client fetches origin/main before scoping: give the fixture a real origin
# whose main is the parent commit, so merge-base(head, origin/main) == base.
git init -q --bare "$work/origin.git"
git -C "$src" remote add origin https://github.com/deanmak13/fakerepo.git
# the configured origin is the GitHub URL; the local bare repo answers it (insteadOf)
git -C "$src" config url."$work/origin.git".insteadOf https://github.com/deanmak13/fakerepo.git
git -C "$src" push -q origin "$base:refs/heads/main"

# A fake profile: the gate passes iff the checked-out f.txt says "two" and
# the file ./PLANT_RED does not exist; it reports where it ran.
cat > "$work/profiles/fake.sh" <<'PROFILE'
profile_cores() { echo "${FAKE_CORES:-2}"; }
profile_mem_mb() { echo "${FAKE_MEM_MB:-512}"; }
profile_scope_report() { echo "fake-scope base=${1:0:8} head=${2:0:8}"; }
profile_env_key() { echo "fakekey1"; }
profile_env_build() { mkdir -p "$1" && echo built > "$1/marker"; }
profile_gate() {
  echo "gate cwd=$PWD home=$HOME tmp=$TMPDIR run=$PNEUMA_GATE_RUN_DIR env=$1"
  echo "lockfd=$(ls -l /proc/$$/fd 2>/dev/null | grep -c admit.lock)"   # no admission lock may be open in the gate
  [ -e untracked-must-not-ship.txt ] && { echo "LEAK: untracked file shipped"; return 3; }
  # the runner scrubs the environment, so the knob is a file beside the profile
  [ -f "$(dirname "${BASH_SOURCE[0]}")/sleep" ] && sleep "$(cat "$(dirname "${BASH_SOURCE[0]}")/sleep")"
  [ "$(cat f.txt)" = two ] && [ ! -e PLANT_RED ] || return 1
}
PROFILE
cp "$work/profiles/fake.sh" "$work/profiles/redfake.sh"
sed -i 's/profile_env_key() { echo "fakekey1"; }/profile_env_key() { echo "fakekey2"; }/; s/\[ "\$(cat f.txt)" = two \]/[ "$(cat f.txt)" = nope ]/' "$work/profiles/redfake.sh"

export PNEUMA_GATE_BASE="$work/base" PNEUMA_GATE_RUN_AS="" PNEUMA_GATE_EXPECT_HOST="" \
       PNEUMA_GATE_PROFILE_DIR="$work/profiles" PNEUMA_GATE_POLL_S=1
mkdir -p "$PNEUMA_GATE_BASE"

# ssh stand-in: drop options + host, run the command locally.
cat > "$work/bin/ssh" <<'SSH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2;; -*) shift;; *) break;; esac; done
shift   # host
exec bash -c "$*"
SSH
chmod +x "$work/bin/ssh"
ENTRY="$REPO_DIR/bin/pneuma-gate-entry"
# sshd's forced command, played here: the client's command arrives as SSH_ORIGINAL_COMMAND and the
# entry point runs it with the submitter it was forced with (test-lane)
cat > "$work/bin/gate-as-forced-command" <<STUB
#!/usr/bin/env bash
SSH_ORIGINAL_COMMAND="\$*" exec "$ENTRY" --submitter test-lane
STUB
cat > "$work/bin/argv-recorder" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ARGV_RECORD"
exit 0
STUB
cat > "$work/bin/sudo-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SUDO_RECORD"
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
exec "$@"
STUB
chmod +x "$work/bin/gate-as-forced-command" "$work/bin/argv-recorder" "$work/bin/sudo-stub"
export SUDO_RECORD="$work/sudo-recorded.txt" PNEUMA_GATE_SUDO="$work/bin/sudo-stub"
export ARGV_RECORD="$work/argv-recorded.txt"
export PATH="$work/bin:$PATH" PNEUMA_GATE_RUNNER="$work/bin/gate-as-forced-command" PNEUMA_GATE_RUNNER_BIN="$RUNNER" PNEUMA_GATE_HOST=fakehost
export PNEUMA_GATE_DEDUP_DIR="$work/dedup"   # GATE-DEDUP-1 state: never under /var/lib in tests
export PNEUMA_GATE_RESULTS_DIR="$work/results"   # the root-owned verdict files: never under /var/lib in tests
# systemd-run stand-in: records its arguments, makes each BindPaths / BindReadOnlyPaths mount
# visible as a symlink for the duration of the command, then runs the command after `--`.
# the gate runs as a unit: stand-ins for systemd-run (runs the command inline) and systemctl
cat > "$work/bin/systemd-run-stub" <<'STUB'
#!/usr/bin/env bash
# While the command runs, its unit is listed as active with the limits it was given
# (what systemd would show), so admission counts it exactly as it would the real unit.
printf '%s\n' "$*" >> "$SCOPE_RECORD"
unit=""; cores=1; mem=0; links=()
for a in "$@"; do
  case "$a" in
    --unit=*) unit="${a#--unit=}.service";;
    --property=CPUQuota=*) q="${a#--property=CPUQuota=}"; q="${q%\%}"; cores=$(( q / 100 ));;
    --property=MemoryMax=*) m="${a#--property=MemoryMax=}"; mem="${m%M}";;
    --property=BindReadOnlyPaths=*|--property=BindPaths=*)
      spec="${a##*Paths=}"; src="${spec%%:*}"; dst="${spec#*:}"
      mkdir -p "$(dirname "$dst")" && { rmdir "$dst" 2>/dev/null; rm -f "$dst"; ln -sfn "$src" "$dst"; } && links+=("$dst");;
    --) break;;
  esac
done
# the unit files are shared by concurrent stubs: every edit is under one lock (a bare `sed -i` loses updates)
cleanup() { local l; for l in "${links[@]}"; do rm -f "$l"; done
  if [ -n "$unit" ] && [ -n "${UNITS_FILE:-}" ]; then
    flock "$UNITS_FILE.lock" bash -c 'sed -i "\|^$1 |d" "$2"; sed -i "\|^$1\$|d" "$3"' _ "$unit" "$UNITS_FILE" "$SYSTEMCTL_ACTIVE"
  fi; }
trap cleanup EXIT
if [ -n "$unit" ] && [ -n "${UNITS_FILE:-}" ]; then
  flock "$UNITS_FILE.lock" bash -c 'printf "%s %s %s\n" "$1" "$2" "$3" >> "$5"; printf "%s\n" "$1" >> "$4"' _ "$unit" "$cores" "$mem" "$SYSTEMCTL_ACTIVE" "$UNITS_FILE"
fi
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
# a real unit gets a scrubbed environment (`env -i`); here the tracer's variables must survive so
# the unit-side code is measured by kcov
if [ "$1" = env ] && [ "$2" = -i ]; then shift 2; set -- env "$@"; fi
"$@"
STUB
chmod +x "$work/bin/systemd-run-stub"
export SCOPE_RECORD="$work/scope-record.txt" PNEUMA_GATE_SYSTEMD_RUN="$work/bin/systemd-run-stub"
# systemctl stand-in: is-active reads $SYSTEMCTL_ACTIVE; list-units and show read $UNITS_FILE
# ("<unit> <cores> <mem_mb>"); a stop is recorded in $SYSTEMCTL_RECORD (the stop record).
cat > "$work/bin/systemctl-stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  is-active) u="${@: -1}"; [ "${SYSTEMCTL_IS_ACTIVE_BROKEN:-0}" = 1 ] && exit 1
             if grep -qx "$u" "$SYSTEMCTL_ACTIVE" 2>/dev/null; then echo active; exit 0; fi; echo inactive; exit 3;;
  list-units) [ "${SYSTEMCTL_FAIL:-0}" = 1 ] && exit 1; pat="${@: -1}"; while read -r u rest; do [[ "$u" == $pat ]] && echo "$u"; done < "$UNITS_FILE" 2>/dev/null; exit 0;;
  show)
    case "$3" in
      CPUQuotaPerSecUSec) awk -v u="$5" '$1 == u { print $2 "s" }' "$UNITS_FILE";;
      MemoryMax) awk -v u="$5" '$1 == u { print $3 * 1048576 }' "$UNITS_FILE";;
      ExecStart) awk -v u="$5" '$1 == u { print "{ path=/usr/bin/env ; argv[]=/usr/bin/env -i PNEUMA_GATE_NONCE=" $2 " /bin/true ; }" }' "$UNIT_NONCES" 2>/dev/null;;
    esac; exit 0;;
  stop) echo "stop $2" >> "${SYSTEMCTL_RECORD:-/dev/null}"; exit 0;;
esac
exit 0
STUB
chmod +x "$work/bin/systemctl-stub"
export PNEUMA_GATE_SYSTEMCTL="$work/bin/systemctl-stub"   # every test: never the host systemctl
export SYSTEMCTL_ACTIVE="$work/systemctl-active.txt" UNITS_FILE="$work/systemctl-units.txt"
export SYSTEMCTL_RECORD="$work/systemctl-record.txt"; : > "$SYSTEMCTL_RECORD"
export PNEUMA_GATE_STATE_DIR="$work/root-state" PNEUMA_GATE_RUN_ROOT="$work/run"   # tests never touch /run or /var/lib
export UNIT_NONCES="$work/unit-nonces.txt"; : > "$UNIT_NONCES"
export PNEUMA_GATE_DYNAMIC_UID_MIN="$(id -u)" PNEUMA_GATE_DYNAMIC_UID_MAX="$(id -u)"   # the stubbed build unit runs as this user
export PNEUMA_GATE_IO_DEVICE=none   # the stubbed units have no disk to cap; the io-cap tests below set a device on purpose
export PNEUMA_GATE_ABORT_FREE_GIB=1   # the disk guard is exercised on purpose below, never by accident
export PNEUMA_GATE_IN_MOUNT="$work/mnt/in" PNEUMA_GATE_ENVS_MOUNT="$work/mnt/envs" \
       PNEUMA_GATE_WHEELS_MOUNT="$work/mnt/wheels" PNEUMA_GATE_UNIT_WORK="$work/unitwork"   # the bind-mount targets and the private disk
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/chown"; chmod +x "$work/bin/chown"
# `ip route` stand-in: records the per-run loopback routes the runner adds and removes
REAL_IP="$(command -v ip)"; export REAL_IP
cat > "$work/bin/ip-stub" <<'STUB'
#!/usr/bin/env bash
[ "${IP_FAIL:-0}" = 1 ] && exit 1
if [ "$1 $2 $3" = "-4 -o addr" ]; then
  if [ -s "$IP_ADDRS" ]; then cat "$IP_ADDRS"; else exec "$REAL_IP" "$@"; fi
  exit 0
fi
if [ "$1 $2 $3" = "route add local" ]; then
  addr="${4%/32}"
  if grep -qx "$addr" "$IP_EXISTS" 2>/dev/null; then echo "RTNETLINK answers: File exists" >&2; exit 2; fi
fi
echo "$*" >> "$IP_RECORD"
if [ "$1 $2 $3 $4" = "route show table local" ]; then cat "$IP_ROUTES" 2>/dev/null; fi
exit 0
STUB
chmod +x "$work/bin/ip-stub"
export PNEUMA_GATE_IP="$work/bin/ip-stub" IP_RECORD="$work/ip-record.txt" IP_ROUTES="$work/ip-routes.txt" IP_ADDRS="$work/ip-addrs.txt" IP_EXISTS="$work/ip-exists.txt"; : > "$IP_RECORD"; : > "$IP_ROUTES"; : > "$IP_ADDRS"; : > "$IP_EXISTS"   # warm-env freezes the env as root; the tests are not root

marker_of() { grep '^PNEUMA_GATE_RESULT ' <<<"$1" | tail -1; }
field_of() { tr ' ' '\n' <<<"$1" | sed -n "s/^$2=//p" | head -1; }

# ── scoping base: the client recomputes it from a fresh origin/main ────────
scope_out=$("$CLIENT" --repo-dir "$src" --head "$head" --base "$head" --scope-only 2>&1) && scope_rc=0 || scope_rc=$?
check "scope-only: exits 0 without a bundle or verdict" test "$scope_rc" = 0
check "scope-only: a stale caller base is overridden by merge-base(head, origin/main)" \
  grep -q "WARNING caller --base ${head:0:12}.* scoping on ${base:0:12}" <<<"$scope_out"
check "scope-only: the scoped base is the merge-base" grep -q "base ${base:0:12} (" <<<"$scope_out"

# Scoping hardening (review of #16): a foreign origin is refused, a head already on
# main is "nothing to gate" (exit 3, never a vacuous green), and the scope report's
# selector runs scrubbed (no ambient secrets reach PR code).
git -C "$src" config remote.origin.url https://github.com/evil/fakerepo.git
evil_out=$("$CLIENT" --repo-dir "$src" --head "$head" --base "$base" --scope-only 2>&1) && evil_rc=0 || evil_rc=$?
check "scope: a foreign origin is refused" bash -c '[ "$1" = 75 ] && grep -q "is not a deanmak13 repository" <<<"$2"' _ "$evil_rc" "$evil_out"
check "scope: a refusal is also written to the refusals log under the git dir (loud, never silent)" \
  bash -c 'grep -q "REFUSED" "$1/.git/pneuma-remote-gate/refusals.log"' _ "$src"
# a planted symlink must not make the client append to another file
victim_log="$work/victim-file"; : > "$victim_log"
rm -f "$src/.git/pneuma-remote-gate/refusals.log"; ln -s "$victim_log" "$src/.git/pneuma-remote-gate/refusals.log"
"$CLIENT" --repo-dir "$src" --head "$head" --base "$base" --scope-only >/dev/null 2>&1 || true
check "refusals log: a symlink is never followed (the victim file stays empty)" test ! -s "$victim_log"
# ASCII-printable only: a refusal that carries a high byte and an ESC sequence logs neither (both become '?').
rm -f "$src/.git/pneuma-remote-gate/refusals.log"
git -C "$src" config remote.origin.url "$(printf 'https://github.com/evil/caf\303\251\033[31m.git')"
"$CLIENT" --repo-dir "$src" --head "$head" --base "$base" --scope-only >/dev/null 2>&1 || true
check "refusals log: a refusal is written, with no byte >= 0x80 and no ESC" bash -c '
  f="$1/.git/pneuma-remote-gate/refusals.log"
  grep -q "REFUSED" "$f" && ! LC_ALL=C grep -q "[^[:print:][:space:]]" "$f"' _ "$src"
git -C "$src" config remote.origin.url https://github.com/deanmak13/fakerepo.git
rm -f "$src/.git/pneuma-remote-gate/refusals.log"
rm -f "$src/.git/pneuma-remote-gate/refusals.log"
git -C "$src" config remote.origin.url https://github.com/deanmak13/fakerepo.git
wt_dir="$work/wt-named-anything"
git -C "$src" worktree add -q --detach "$wt_dir" "$head" 2>/dev/null
wt_out=$("$CLIENT" --repo-dir "$wt_dir" --head "$head" --base "$base" --scope-only 2>&1) && wt_rc=0 || wt_rc=$?
check "name: a worktree named anything works: the repo name comes from the origin remote" \
  bash -c '[ "$1" = 0 ] && grep -q "scope-only head" <<<"$2"' _ "$wt_rc" "$wt_out"
git -C "$src" worktree remove --force "$wt_dir" 2>/dev/null || true
git -C "$src" config remote.origin.url https://github.com/deanmak13/fakerepo.git
done_out=$("$CLIENT" --repo-dir "$src" --head "$base" --base "$base" --scope-only 2>&1) && done_rc=0 || done_rc=$?
check "scope: a head already on origin/main is NOTHING TO GATE (exit 3, not 0)" bash -c '[ "$1" = 3 ] && grep -q "NOTHING TO GATE" <<<"$2"' _ "$done_rc" "$done_out"

# Mutation guards (review of #16): the scoping base must come from FETCH_HEAD, not
# from a refs/remotes/origin/main that a fetch did not rewrite. Here the fetch only
# updates refs/remotes/other/*, and refs/remotes/origin/main is left pointing at the
# head itself. Reading the stale ref would scope on merge-base(head, head) and call
# the head "nothing to gate"; FETCH_HEAD gives the real base.
git -C "$src" config remote.origin.fetch '+refs/heads/*:refs/remotes/other/*'
git -C "$src" update-ref refs/remotes/origin/main "$head"
fh_out=$("$CLIENT" --repo-dir "$src" --head "$head" --base "$base" --scope-only 2>&1) && fh_rc=0 || fh_rc=$?
check "scope: the base comes from FETCH_HEAD (a stale refs/remotes/origin/main is ignored)" \
  bash -c '[ "$1" = 0 ] && grep -q "base '"${base:0:12}"'" <<<"$2"' _ "$fh_rc" "$fh_out"
git -C "$src" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
git -C "$src" update-ref refs/remotes/origin/main "$base"

# The engine profile's scope report, run in a throwaway checkout whose selector is
# a stub: the test covers the report's plumbing (diff count, selector grep), not
# the selector itself (tools/ci has its own suite).
ENGINE_PROFILE="$(cd "$(dirname "$CLIENT")/.." && pwd)/gate-profiles/engine.sh"
scope_repo="$work/scope-repo"
mkdir -p "$scope_repo/tools/ci"
git -C "$scope_repo" init -q -b main
printf 'a\n' > "$scope_repo/a.txt"; git -C "$scope_repo" add a.txt; git -C "$scope_repo" commit -qm a
scope_base=$(git -C "$scope_repo" rev-parse HEAD)
printf 'b\n' > "$scope_repo/b.txt"; git -C "$scope_repo" add b.txt; git -C "$scope_repo" commit -qm b
scope_head=$(git -C "$scope_repo" rev-parse HEAD)
printf '%s\n' "import os, sys" "open('stub-env.txt', 'w').write(repr(sorted(os.environ)))" "print(\"services selected: ['svc']\")" "print(\"connectors selected: ['<none>']\")" "print(\"  always-on guards (never scoped away): ruff-added-lines\")" \
  > "$scope_repo/tools/ci/detect_changed_services.py"
report_out=$(cd "$scope_repo" && SECRET_TEST_TOKEN=leak bash -c 'source "$1"; profile_scope_report "$2" "$3"' _ "$ENGINE_PROFILE" "$scope_base" "$scope_head" 2>&1)
check "engine profile: scope report counts the changed files" grep -q "1 changed file(s) vs base ${scope_base:0:12}" <<<"$report_out"
check "engine profile: the scope report's selector runs scrubbed (no ambient secret)" bash -c '! grep -q SECRET_TEST_TOKEN "$1/stub-env.txt"' _ "$scope_repo"
check "engine profile: scope report lists the always-on guards line" grep -q "always-on guards" <<<"$report_out"
check "engine profile: scope report shows the selected services" grep -q "services selected: \['svc'\]" <<<"$report_out"

# The scope report runs the head's selector (PR code): it must be time-bounded.
hang_repo="$work/hang-repo"; mkdir -p "$hang_repo/tools/ci"
git -C "$hang_repo" init -q -b main
printf 'a\n' > "$hang_repo/a.txt"; git -C "$hang_repo" add a.txt; git -C "$hang_repo" commit -qm a
hang_base=$(git -C "$hang_repo" rev-parse HEAD)
printf 'b\n' > "$hang_repo/b.txt"; git -C "$hang_repo" add b.txt; git -C "$hang_repo" commit -qm b
hang_head=$(git -C "$hang_repo" rev-parse HEAD)
printf '%s\n' "import time" "time.sleep(30)" > "$hang_repo/tools/ci/detect_changed_services.py"
hang_t0=$(date +%s)
hang_out=$(cd "$hang_repo" && PNEUMA_SCOPE_TIMEOUT_S=2 bash -c 'source "$1"; profile_scope_report "$2" "$3"' _ "$ENGINE_PROFILE" "$hang_base" "$hang_head" 2>&1 || true)
hang_secs=$(( $(date +%s) - hang_t0 ))
check "scope report: a hanging selector is killed by the time limit (returns in seconds, not 30)" test "$hang_secs" -lt 15
check "scope report: a killed selector yields no services line (no false selection)" bash -c '! grep -q "services selected" <<<"$1"' _ "$hang_out"


# ── engine profile: the per-run live-Postgres cluster (GATE-PG-1) ─────────
# Stub PostgreSQL binaries and ss record their calls; the bring-up, the loopback
# assertion and the teardown code run for real. A live cluster is exercised on
# ci-builder, not here.
pgstub="$work/pgstub"; mkdir -p "$pgstub"
cat > "$pgstub/initdb" <<'STUB'
#!/usr/bin/env bash
d=""; for a in "$@"; do case "$a" in -D) n=1;; *) [ "${n:-0}" = 1 ] && d="$a" && n=0;; esac; done
[ "${PG_STUB_INITDB_FAIL:-0}" = 1 ] && exit 1
mkdir -p "$d" && echo initdb >> "$(dirname "$d")/calls"
STUB
cat > "$pgstub/pg_ctl" <<'STUB'
#!/usr/bin/env bash
d=""; prev=""; for a in "$@"; do [ "$prev" = -D ] && d="$a"; prev="$a"; done
echo "pg_ctl $*" >> "$(dirname "$d")/calls"
STUB
cat > "$pgstub/ss" <<'STUB'
#!/usr/bin/env bash
port="$(grep -o -- '-p [0-9]*' "$PG_STUB_CALLS" | head -1 | cut -d' ' -f2)"
case "${PG_STUB_SS:-loopback}" in
  loopback) echo "LISTEN 0 4096 ${PG_STUB_HOST:-127.0.0.1}:$port 0.0.0.0:*";;
  wild)     echo "LISTEN 0 4096 0.0.0.0:$port 0.0.0.0:*";;
  none)     :;;
esac
STUB
chmod +x "$pgstub"/*
pg_case() {  # <name> → a fresh run dir; sets PGRUN and PG_STUB_CALLS
  PGRUN="$work/pgrun-$1"; mkdir -p "$PGRUN"; PG_STUB_CALLS="$PGRUN/pg/calls"; export PG_STUB_CALLS
}

pg_case missing
pg_none=$(PNEUMA_GATE_PG_BIN="$work/no-such-bin" bash -c 'unset INTEGRATION_TEST PGTEST_DSN; source "$1"; _engine_pg_up "$2"; echo "rc=$?"' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "live-pg: missing binaries FAIL the gate (rc=1), never SKIPPED-and-green" grep -q "rc=1" <<<"$pg_none"
check "live-pg: the missing-binaries failure is named" grep -q "cannot be green" <<<"$pg_none"

pg_case loopback
pg_ok=$(PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2" && echo "dsn=$PGTEST_DSN int=$INTEGRATION_TEST"; _engine_pg_down' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
PG_CAPS_CALLS="$PGRUN/pg/calls"
PG_CAPS_CALLS="$PGRUN/pg/calls"
check "live-pg: exports a loopback DSN and INTEGRATION_TEST=1" grep -qE "^dsn=postgresql://gate:[A-Za-z0-9]{32}@127\.0\.0\.1:[0-9]+/postgres int=1$" <<<"$pg_ok"
check "live-pg: the cluster is stopped on teardown" grep -q "pg_ctl -D $PGRUN/pg/data -m immediate -w stop" "$PG_STUB_CALLS"
check "live-pg: the password file is private" test "$(stat -c %a "$PGRUN/pg/pw")" = 600

pg_case ownlo
pg_own=$(PG_STUB_HOST=127.55.1.2 PNEUMA_GATE_LOOPBACK=127.55.1.2 PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2" && echo "dsn=$PGTEST_DSN"; _engine_pg_down' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "live-pg: with a per-run loopback address the DSN and the listen address use it" bash -c 'grep -q "@127\.55\.1\.2:" <<<"$1" && grep -q "listen_addresses=127.55.1.2" "$2"' _ "$pg_own" "$PG_STUB_CALLS"
check "live-pg: pg_hba admits the run's own address with scram" grep -qx 'host all all 127.55.1.2/32 scram-sha-256' "$PGRUN/pg/data/pg_hba.conf"
pg_case ownlo-bad
pg_ownbad=$(PG_STUB_HOST=127.0.0.1 PNEUMA_GATE_LOOPBACK=127.55.1.2 PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2"; echo "rc=$?"' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "live-pg: a listener on 127.0.0.1 when the run's address is 127.55.1.2 FAILS the gate" bash -c 'grep -q "rc=1" <<<"$1" && grep -q "beyond 127.55.1.2" <<<"$1"' _ "$pg_ownbad"

pg_case wild
pg_wild=$(PG_STUB_SS=wild PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2"; echo "rc=$?"' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "live-pg: a listener beyond 127.0.0.1 FAILS the gate and stops the cluster" bash -c 'grep -q "rc=1" <<<"$1" && grep -q "beyond 127.0.0.1" <<<"$1" && grep -q "stop" "$2"' _ "$pg_wild" "$PG_STUB_CALLS"

pg_case none
pg_nolisten=$(PG_STUB_SS=none PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2"; echo "rc=$?"' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "live-pg: no listener at all FAILS the gate" grep -q "nothing listens" <<<"$pg_nolisten"

pg_case fail
pg_fail=$(PG_STUB_INITDB_FAIL=1 PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2"; echo "rc=$?"' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "live-pg: a failed initdb fails the gate" grep -q "rc=1" <<<"$pg_fail"

pg_case chain
chain_log="$work/chain.log"; : > "$chain_log"
mkdir -p "$PGRUN/pg/data"; : > "$PG_STUB_CALLS"
PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c '
  trap "echo previous-exit-handler >> '"$chain_log"'" EXIT
  source "$1"; _ENGINE_PG_ROOT="$2/pg"; _engine_pg_arm_exit' _ "$ENGINE_PROFILE" "$PGRUN"
check "live-pg: a previous EXIT handler still runs (chained, not replaced)" grep -q "previous-exit-handler" "$chain_log"
check "live-pg: the cluster is stopped by the same EXIT handler" grep -q "pg_ctl -D $PGRUN/pg/data -m immediate -w stop" "$PG_STUB_CALLS"

# ── engine profile: the live junit verdict (GATE-PG-1) ──────────────────
# The live verdict on canned junit reports (the same function the gate runs).
mkdir -p "$work/live"
cat > "$work/live/ok.xml" <<'XML'
<testsuites><testsuite><testcase classname="tests.integration.test_a" name="t1"/><testcase classname="tests.integration.test_b" name="t2"/></testsuite></testsuites>
XML
cat > "$work/live/dsn-skip.xml" <<'XML'
<testsuites><testsuite><testcase classname="tests.integration.test_a" name="t1"/><testcase classname="tests.integration.test_b" name="t2"><skipped message="PGTEST_DSN is not set. Run via tools/ci/with_test_postgres.sh"/></testcase></testsuite></testsuites>
XML
cat > "$work/live/module-missing.xml" <<'XML'
<testsuites><testsuite><testcase classname="tests.integration.test_a" name="t1"/></testsuite></testsuites>
XML
cat > "$work/live/module-all-skipped.xml" <<'XML'
<testsuites><testsuite><testcase classname="tests.integration.test_a" name="t1"/><testcase classname="tests.integration.test_b" name="t2"><skipped message="no psycopg"/></testcase></testsuite></testsuites>
XML
verdict() {  # <junit> → output, then rc=<n>
  bash -c 'source "$1"; _engine_live_verdict "$2" tests/integration/test_a.py tests/integration/test_b.py' _ "$ENGINE_PROFILE" "$1" 2>&1; echo "rc=$?"
}
check "live verdict: all modules ran, none skipped for the DSN -> green" grep -q "rc=0" <<<"$(verdict "$work/live/ok.xml")"
check "live verdict: a DSN skip with the cluster up -> RED" grep -q "skipped for a missing PGTEST_DSN" <<<"$(verdict "$work/live/dsn-skip.xml")"
check "live verdict: a DSN skip -> rc=1" grep -q "rc=1" <<<"$(verdict "$work/live/dsn-skip.xml")"
check "live verdict: a module whose live tests all skipped -> RED" grep -q "ran no live test" <<<"$(verdict "$work/live/module-all-skipped.xml")"
check "live verdict: a module absent from the report -> RED" grep -q "ran no live test" <<<"$(verdict "$work/live/module-missing.xml")"
check "live verdict: an unreadable report -> RED" grep -q "no readable live junit report" <<<"$(verdict "$work/live/absent.xml")"
check "live verdict: zero live modules on disk -> RED (no fail-open)" bash -c 'source "$1"; _engine_live_verdict "$2" >/dev/null 2>&1; test $? = 1' _ "$ENGINE_PROFILE" "$work/live/ok.xml"

# Discovery is from disk: callers of require_pgtest_dsn(), never the definition itself.
disc="$work/disc"; mkdir -p "$disc/tests/integration" "$disc/tools/ci"
git -C "$disc" init -q -b main
printf 'from tools.ci.pgtest_env import require_pgtest_dsn\nDSN = require_pgtest_dsn()\n' > "$disc/tests/integration/test_a.py"
printf 'def require_pgtest_dsn() -> str:\n    pass\n' > "$disc/tools/ci/pgtest_env.py"
printf 'x = 1\n' > "$disc/tests/integration/test_plain.py"
git -C "$disc" add -A && git -C "$disc" -c user.name=t -c user.email=t@t commit -qm d
disc_out="$(cd "$disc" && bash -c 'source "$1"; _engine_live_modules' _ "$ENGINE_PROFILE")"
check "live discovery: finds the caller, not the definition or plain tests" test "$disc_out" = "tests/integration/test_a.py"

# profile_gate end to end, with a stub venv whose python writes a canned junit report:
# the live step's wiring runs for real (discovery, pytest call, verdict, exit status).
live_repo="$work/live-repo"; mkdir -p "$live_repo/.githooks" "$live_repo/tests/integration"
printf '#!/usr/bin/env bash\nexit 0\n' > "$live_repo/.githooks/pre-push"; chmod +x "$live_repo/.githooks/pre-push"
printf 'from tools.ci.pgtest_env import require_pgtest_dsn\nDSN = require_pgtest_dsn()\n' > "$live_repo/tests/integration/test_a.py"
printf 'from tools.ci.pgtest_env import require_pgtest_dsn\nDSN = require_pgtest_dsn()\n' > "$live_repo/tests/integration/test_b.py"
git -C "$live_repo" init -q -b main; git -C "$live_repo" add -A
git -C "$live_repo" -c user.name=t -c user.email=t@t commit -qm live
mkdir -p "$work/gvenv/venv/bin"
cat > "$work/gvenv/venv/bin/python" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in --junitxml=*) f="${a#--junitxml=}";; esac; done
cp "$CANNED_JUNIT" "$f"
STUB
chmod +x "$work/gvenv/venv/bin/python"
mkdir -p "$work/gbase/runs" "$work/ghome"
live_gate() {  # <canned junit> → the profile_gate verdict
  pg_case "live-$(basename "$1")"
  (cd "$live_repo" && HOME="$work/ghome" PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" PNEUMA_GATE_BASE="$work/gbase" \
    PNEUMA_GATE_RUN_DIR="$PGRUN" PNEUMA_GATE_CORES=1 PG_STUB_SS=loopback CANNED_JUNIT="$1" \
    bash -c 'source "$1"; profile_gate "$2" h b 60; echo "rc=$?"' _ "$ENGINE_PROFILE" "$work/gvenv" 2>&1)
}
check "profile_gate: live modules all ran (junit ok) -> the gate is green" grep -q "rc=0" <<<"$(live_gate "$work/live/ok.xml")"
check "profile_gate: a DSN skip in the live run -> the gate is RED" grep -q "rc=1" <<<"$(live_gate "$work/live/dsn-skip.xml")"

# ── client end to end ────────────────────────────────────────────────────────
out=$("$CLIENT" --repo-dir "$src" --profile fake --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
echo "DBG:$out" >&2
expect_eq "client: green gate exits 0" 0 "$rc"
check "runner: the profile scope report opens the log" grep -q "scope: fake-scope base=" <<<"$out"
check "client: log names the exact head and tree" grep -q "$head" <<<"$out"
check "client: log kept on the dev side" test -n "$(ls "$work/logs"/*.log)"
check "client: dirty worktree file was NOT shipped (no LEAK)" not grep -q LEAK <<<"$out"
expect_eq "the root runner leaves nothing: no queue ticket, reservation or staged bundle" 0 "$(find "$PNEUMA_GATE_BASE/queue" "$PNEUMA_GATE_STATE_DIR/runs" "$PNEUMA_GATE_STATE_DIR/in" -mindepth 1 | wc -l)"
expect_eq "queue entries are removed after a run" 0 "$(find "$PNEUMA_GATE_BASE/queue" -mindepth 1 | wc -l)"
check "a run builds its env privately and never publishes it to the shared cache" test -z "$(ls -A "$PNEUMA_GATE_BASE/envs/fake")"
check "the run's env was built inside the unit (not cached)" grep -q 'not cached' <<<"$out"
# a cache HIT: the published env is mounted read-only into the unit, and used as is
mkdir -p "$PNEUMA_GATE_BASE/envs/fake/fakekey1" && touch "$PNEUMA_GATE_BASE/envs/fake/fakekey1/.ready"
hit_out=$("$CLIENT" --repo-dir "$src" --profile fake --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && hit_rc=0 || hit_rc=$?
expect_eq "cache hit: the gate is green" 0 "$hit_rc"
check "cache hit: the run uses the read-only shared cache at the unit's mount" grep -q "env=$PNEUMA_GATE_ENVS_MOUNT/fakekey1" <<<"$hit_out"
check "cache hit: the cache is bound read-only into the unit" grep -q -- "--property=BindReadOnlyPaths=$PNEUMA_GATE_BASE/envs/fake:$PNEUMA_GATE_ENVS_MOUNT" "$SCOPE_RECORD"
rm -rf "$PNEUMA_GATE_BASE/envs/fake/fakekey1"
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null || true

out=$("$CLIENT" --repo-dir "$src" --profile redfake --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
expect_eq "client: red gate exits 1" 1 "$rc"
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null || true

out=$(PNEUMA_GATE_MIN_FREE_GIB=99999999 "$CLIENT" --repo-dir "$src" --profile fake --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
expect_eq "client: free space under the floor exits 75 (no verdict)" 75 "$rc"
check "disk refusal says why" grep -q 'refusing to start' <<<"$out"
out=$(PNEUMA_GATE_MIN_FREE_GIB=1 "$CLIENT" --repo-dir "$src" --profile fake --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
expect_eq "client: ample free space (floor 1GiB) is admitted regardless of percent used" 0 "$rc"
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null || true

out=$("$RUNNER" status 2>&1)
check "status reports the free-space floor" grep -q 'disk_free>=40GiB' <<<"$out"

out=$(PNEUMA_GATE_EXPECT_HOST=not-the-builder "$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1) && rc=0 || rc=$?
expect_eq "runner: wrong host identity exits 75" 75 "$rc"
out=$("$CLIENT" --repo-dir "$src" --profile nosuchprofile --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
expect_eq "client: unknown profile exits 75" 75 "$rc"

# client must reject a verdict for a different commit / from a different host
printf '%s\n' '#!/usr/bin/env bash' 'echo "PNEUMA_GATE_RESULT repo=fakerepo head=0000000000000000000000000000000000000000 tree=0000000000000000000000000000000000000000 profile=fake exit=0 elapsed=1s host=fakehost"' > "$work/bin/lying-runner"
chmod +x "$work/bin/lying-runner"
out=$(PNEUMA_GATE_RUNNER="$work/bin/lying-runner" "$CLIENT" --repo-dir "$src" --profile fake --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
expect_eq "client: PASS marker for another commit is NOT green" 75 "$rc"
printf '%s\n' '#!/usr/bin/env bash' "echo \"PNEUMA_GATE_RESULT repo=fakerepo head=$head tree=$tree profile=fake exit=0 elapsed=1s host=evilhost\"" > "$work/bin/wrong-host-runner"
chmod +x "$work/bin/wrong-host-runner"
out=$(PNEUMA_GATE_EXPECT_HOST=vmi3387590 PNEUMA_GATE_RUNNER="$work/bin/wrong-host-runner" "$CLIENT" --repo-dir "$src" --profile fake --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
expect_eq "client: PASS from a non-approved host is NOT green" 75 "$rc"
printf '%s\n' '#!/usr/bin/env bash' 'echo "some log, then the connection dropped"; exit 255' > "$work/bin/dropped-runner"
chmod +x "$work/bin/dropped-runner"
out=$(PNEUMA_GATE_RUNNER="$work/bin/dropped-runner" "$CLIENT" --repo-dir "$src" --profile fake --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
expect_eq "client: no marker (dropped connection) is NOT green" 75 "$rc"

# ── resource scope: the gate runs in a transient systemd scope with the run's budget,
# and the per-run PostgreSQL is capped (GATE-PG-1 review) ─────────────────────────
check "service: the gate runs as a transient SERVICE named for its run" grep -q -- "--unit=pneuma-gate-" "$SCOPE_RECORD"
check "service: KillMode=control-group (the whole cgroup dies with the unit)" grep -q -- "--property=KillMode=control-group" "$SCOPE_RECORD"
check "service: MemoryMax = the admitted mem" grep -q -- "--property=MemoryMax=512M" "$SCOPE_RECORD"
check "service: CPUQuota = cores x 100%" grep -q -- "--property=CPUQuota=200%" "$SCOPE_RECORD"
check "service: TasksMax is capped" grep -q -- "--property=TasksMax=512" "$SCOPE_RECORD"
check "service: a hard RuntimeMaxSec cap" grep -q -- "--property=RuntimeMaxSec=" "$SCOPE_RECORD"
for prop in DynamicUser=yes PrivateTmp=yes ProtectSystem=strict ProtectHome=yes NoNewPrivileges=yes ProtectProc=invisible \
            MemorySwapMax=0 "RuntimeDirectory=pneuma-gate/" RuntimeDirectoryMode=0700; do
  check "service: sandbox property $prop" grep -q -- "--property=$prop" "$SCOPE_RECORD"
done
check "service: the bundle is placed read-only (BindReadOnlyPaths), not unpacked by the runner" grep -q -- "--property=BindReadOnlyPaths=$PNEUMA_GATE_STATE_DIR/in/.*bundle:$PNEUMA_GATE_IN_MOUNT/bundle" "$SCOPE_RECORD"
check "service: the object store is read-only to the unit" grep -q -- "--property=BindReadOnlyPaths=$PNEUMA_GATE_BASE/repos/fakerepo.git:$PNEUMA_GATE_IN_MOUNT/store" "$SCOPE_RECORD"
check "service: the unit's limits are the profile's fixed numbers (never PR content)" bash -c 'grep -q "MemoryMax=512M" "$1" && grep -q "CPUQuota=200%" "$1"' _ "$SCOPE_RECORD"
check "promote: the store is written only by its own sandboxed unit (no network)" bash -c 'grep -q -- "--unit=pneuma-promote-" "$1" && grep -q -- "--property=PrivateNetwork=yes" "$1"' _ "$SCOPE_RECORD"
check "service: promote and warm units are never named like a gate unit (admission counts gate units only)" not grep -q -- "--unit=pneuma-gate-promote" "$SCOPE_RECORD"
check "PG: the per-run postmaster is capped (shared_buffers, connections)" bash -c 'grep -q "shared_buffers=128MB" "$1" && grep -q "max_connections=50" "$1"' _ "$PG_CAPS_CALLS"
check "scope: no systemd-run means refusal, never an unscoped gate" bash -c 'PNEUMA_GATE_SYSTEMD_RUN=/nonexistent "$1" run --profile fake --repo fakerepo --head "$2" --base "$3" --tree "$4" >/dev/null 2>&1; test $? = 75' _ "$RUNNER" "$head" "$base" "$tree"

# ── runner: tree mismatch, shallow boundary, have ────────────────────────────
out=$("$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$base" 2>&1) && rc=0 || rc=$?
expect_eq "runner: tree mismatch exits 75" 75 "$rc"
check "have: reports commits the store holds" bash -c "[ \"\$('$RUNNER' have --repo fakerepo '$head' 1111111111111111111111111111111111111111)\" = '$head' ]"
check "have: rejects a hostile repo name" not "$RUNNER" have --repo '../x' "$head"
out=$("$RUNNER" run --submitter test-lane --profile 'a/b' --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1) && rc=0 || rc=$?
expect_eq "runner: hostile profile name exits 75" 75 "$rc"

shallow_src="$work/shallow-src"
git clone -q --depth 2 "file://$src" "$shallow_src" 2>/dev/null
sh_head=$(git -C "$shallow_src" rev-parse HEAD)
# its origin must be this repo (the client checks), and main must be the parent
# commit so the shallow head is genuinely unmerged
git -C "$shallow_src" remote set-url origin https://github.com/deanmak13/shallow-src.git
git -C "$shallow_src" config url."$work/origin.git".insteadOf https://github.com/deanmak13/shallow-src.git
printf 'two\n' > /dev/null
out=$("$CLIENT" --repo-dir "$shallow_src" --profile fake --head "$sh_head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
expect_eq "client: a shallow dev-box clone ships and gates" 0 "$rc"
# a depth-1 clone has no parent, so no merge-base: refuse, never scope blind
d1_src="$work/depth1-src"
git clone -q --depth 1 "file://$src" "$d1_src" 2>/dev/null
git -C "$d1_src" remote set-url origin https://github.com/deanmak13/depth1-src.git
git -C "$d1_src" config url."$work/origin.git".insteadOf https://github.com/deanmak13/depth1-src.git
d1_out=$("$CLIENT" --repo-dir "$d1_src" --head "$(git -C "$d1_src" rev-parse HEAD)" --base "$base" --scope-only 2>&1) && d1_rc=0 || d1_rc=$?
check "scope: a depth-1 clone is refused (no merge-base, exit 75)" bash -c '[ "$1" = 75 ] && grep -q "no merge-base" <<<"$2"' _ "$d1_rc" "$d1_out"
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null || true

# ── capacity admission (pure function, fake host numbers) ───────────────────
mem="$work/meminfo"; load="$work/loadavg"
admit() {   # admit <nproc> <avail_mb> <load1> <live gates> <cores> <mem_mb>  -> exit 0 if admitted
  printf 'MemAvailable: %d kB\n' $(($2 * 1024)) > "$mem"
  printf '%s 1 1 1/1 1\n' "$3" > "$load"
  rm -rf "$work/cap" && mkdir -p "$work/cap/runs"
  local i
  : > "$work/cap/units"
  for ((i = 0; i < $4; i++)); do printf 'pneuma-gate-r%s.service %s %s\n' "$i" "$5" "$6" >> "$work/cap/units"; done
  PNEUMA_GATE_SYSTEMCTL="$work/bin/systemctl-stub" UNITS_FILE="$work/cap/units" SYSTEMCTL_ACTIVE="$work/cap/units" \
    PNEUMA_GATE_BASE="$work/cap" PNEUMA_GATE_NPROC="$1" PNEUMA_GATE_MEMINFO="$mem" PNEUMA_GATE_LOADAVG="$load" \
    bash -c "source '$RUNNER'; can_admit $5 $6"
}
check "capacity: 8 cores, 18G free, idle -> first gate admitted" admit 8 18000 1.0 0 2 3072
check "capacity: second gate fits beside the first (reserve 3 of 8)" admit 8 18000 1.0 1 2 3072
check "capacity: third gate refused (2+2+2 > 8-3)" not admit 8 18000 1.0 2 2 3072
check "capacity: refused when free memory minus reserve < need" not admit 8 8000 1.0 0 2 3072
check "capacity: tiny host still runs ONE gate" admit 2 18000 1.0 0 2 3072
check "capacity: saturated host (load > 1.5x cores) refuses to stack a 2nd gate" not admit 8 18000 14.0 1 2 3072
check "capacity: saturated host still admits the first gate" admit 8 18000 14.0 0 2 3072
check "capacity: hard concurrency cap (4) holds" not env PNEUMA_GATE_MAX_CONCURRENT=1 bash -c "$(declare -f admit); work='$work'; mem='$mem'; load='$load'; RUNNER='$RUNNER'; admit 64 99000 1.0 1 1 100"

# ── two concurrent gates, then a third that must queue (FIFO), all clean ─────
echo 6 > "$work/profiles/sleep"
export PNEUMA_GATE_NPROC=8 PNEUMA_GATE_RESERVE_CORES=3 PNEUMA_GATE_RESERVE_MEM_MB=0
printf 'MemAvailable: %d kB\n' $((64 * 1024 * 1024)) > "$mem"; printf '0.1 1 1 1/1 1\n' > "$load"
export PNEUMA_GATE_MEMINFO="$mem" PNEUMA_GATE_LOADAVG="$load"
export PNEUMA_GATE_SYSTEMCTL="$work/bin/systemctl-stub"; : > "$UNITS_FILE"; : > "$SYSTEMCTL_ACTIVE"
for i in 1 2 3; do
  # distinct submitters: three identical scopes would (correctly) attach to ONE job, and this test wants three runs
  ( "$RUNNER" run --submitter "conc-$i" --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" > "$work/c$i.out" 2>&1; echo $? > "$work/c$i.rc" ) &
  sleep 1
done
sleep 3
live=$(wc -l < "$UNITS_FILE")   # the active gate units, as systemd reports them
expect_eq "concurrency: exactly 2 gates run at once, the 3rd waits" 2 "$live"
wait
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null || true
expect_eq "concurrency: all three finished green" "0 0 0" "$(cat "$work/c1.rc" "$work/c2.rc" "$work/c3.rc" | tr '\n' ' ' | sed 's/ $//')"
check "concurrency: the 3rd logged that it queued" grep -q 'queued:' "$work/c3.out"
check "concurrency: each run used its OWN workspace" bash -c "[ \$(cat '$work'/c?.out | grep -o 'cwd=[^ ]*' | sort -u | wc -l) = 3 ]"
check "concurrency: runs were isolated HOME/TMPDIR" bash -c "[ \$(cat '$work'/c?.out | grep -o 'home=[^ ]*' | sort -u | wc -l) = 3 ]"
expect_eq "concurrency: nothing left behind" 0 "$(find "$PNEUMA_GATE_BASE/queue" "$PNEUMA_GATE_STATE_DIR/runs" "$PNEUMA_GATE_STATE_DIR/in" -mindepth 1 | wc -l)"
rm -f "$work/profiles/sleep"

# ── janitor: the runner's own leftovers only; systemd owns run directories ─────
export PNEUMA_GATE_RUN_ROOT="$work/run"; mkdir -p "$PNEUMA_GATE_RUN_ROOT"
old=$(( $(date +%s) - 7200 ))
leftover="$PNEUMA_GATE_RUN_ROOT/leftover-1"; mkdir -p "$leftover/work"; touch -d "@$old" "$leftover"
"$RUNNER" janitor >/dev/null 2>&1
check "janitor: never deletes a run directory (systemd owns it)" test -d "$leftover"
check "janitor: never sends a unit a stop (systemd owns the lifetime)" bash -c '! grep -q "^stop " "$1"' _ "$SYSTEMCTL_RECORD"
check "fresh host: only the object store is handed to the static gate user" grep -q 'chown "$RUN_AS" "$BASE_DIR/repos"' "$RUNNER"
check "no run dir is read for any decision: the runner never reads cores/pid/owner files from a run directory" not grep -qE 'RUN_ROOT/[^ ]*/(pid|cores|owner)' "$RUNNER"

# RESERVATIONS count while their runner is alive, never by age (slow start): a marker whose
# runner is live counts however old; a dead runner's, or a recycled pid's, does not.
mkdir -p "$PNEUMA_GATE_STATE_DIR/runs" "$PNEUMA_GATE_STATE_DIR/in"; : > "$UNITS_FILE"; : > "$SYSTEMCTL_ACTIVE"
sleep 300 & live_pid=$!
bash -c 'source "$1"; state_mark live-1 "$2" 2 1024' _ "$RUNNER" "$live_pid"
touch -d "@$old" "$PNEUMA_GATE_STATE_DIR/runs/live-1"
check "reservation: a live runner's reservation counts even when it is hours old" bash -c 'source "$1"; live_runs | grep -x "live-1 2 1024" >/dev/null' _ "$RUNNER"
printf 'pid=%s\npstart=1\ncores=2\nmem_mb=1024\n' "$live_pid" > "$PNEUMA_GATE_STATE_DIR/runs/recycled-1"
check "reservation: a recycled pid (start time differs) is not the runner" bash -c 'source "$1"; ! live_runs | grep "^recycled-1 " >/dev/null' _ "$RUNNER"
rm -f "$PNEUMA_GATE_STATE_DIR/runs/recycled-1"
printf 'pid=999999\npstart=1\ncores=2\nmem_mb=1024\n' > "$PNEUMA_GATE_STATE_DIR/runs/dead-1"
check "reservation: a dead runner's reservation does not count" bash -c 'source "$1"; ! live_runs | grep "^dead-1 " >/dev/null' _ "$RUNNER"
printf 'pid=nonsense\n' > "$PNEUMA_GATE_STATE_DIR/runs/junk-1"
check "reservation: a MALFORMED marker still counts (unknown liveness is occupied, not free)" bash -c 'source "$1"; live_runs | grep "^junk-1 " >/dev/null' _ "$RUNNER"
sleep 300 & queued_pid=$!
# a QUEUED runner staged its bundle before it holds capacity: its marker (pid + start time) keeps it
bash -c 'source "$1"; state_mark y-1 "$2" 1 256 queued' _ "$RUNNER" "$queued_pid"
printf 'pid=%s\npstart=1\ncores=1\nmem_mb=256\nstate=queued\n' "$queued_pid" > "$PNEUMA_GATE_STATE_DIR/runs/r-1"   # a recycled pid
: > "$PNEUMA_GATE_STATE_DIR/in/x-999999.bundle"; : > "$PNEUMA_GATE_STATE_DIR/in/y-1.bundle"; : > "$PNEUMA_GATE_STATE_DIR/in/r-1.bundle"; : > "$PNEUMA_GATE_STATE_DIR/in/live-1.bundle"
check "reservation: a queued marker holds no capacity" bash -c 'source "$1"; ! live_runs | grep "^y-1 " >/dev/null' _ "$RUNNER"
"$RUNNER" janitor >/dev/null 2>&1
check "janitor: removes the marker of a dead runner" test ! -e "$PNEUMA_GATE_STATE_DIR/runs/dead-1"
check "janitor: removes the staged bundle of a dead runner" test ! -e "$PNEUMA_GATE_STATE_DIR/in/x-999999.bundle"
check "janitor: keeps a QUEUED live runner's bundle (marker pid + start time match)" test -e "$PNEUMA_GATE_STATE_DIR/in/y-1.bundle"
check "janitor: a recycled pid (start time differs) does not keep a marker or its bundle" bash -c '[ ! -e "$1/runs/r-1" ] && [ ! -e "$1/in/r-1.bundle" ]' _ "$PNEUMA_GATE_STATE_DIR"
check "janitor: keeps a live runner's marker and bundle" test -e "$PNEUMA_GATE_STATE_DIR/runs/live-1" -a -e "$PNEUMA_GATE_STATE_DIR/in/live-1.bundle"
printf 'pneuma-gate-z-999999.service\n' > "$SYSTEMCTL_ACTIVE"; : > "$PNEUMA_GATE_STATE_DIR/in/z-999999.bundle"
"$RUNNER" janitor >/dev/null 2>&1
check "janitor: keeps the bundle of a run whose unit is still active" test -e "$PNEUMA_GATE_STATE_DIR/in/z-999999.bundle"
: > "$SYSTEMCTL_ACTIVE"; kill "$live_pid" "$queued_pid" 2>/dev/null; rm -f "$PNEUMA_GATE_STATE_DIR"/runs/* "$PNEUMA_GATE_STATE_DIR"/in/*
# queue tickets carry "<pid> <start time>": a dead pid and a recycled pid are both reaped, a live one is kept
sleep 300 & tk_pid=$!
dead_ticket="$PNEUMA_GATE_BASE/queue/1-999999"; printf '999999 1\n' > "$dead_ticket"
recycled_ticket="$PNEUMA_GATE_BASE/queue/2-$tk_pid"; printf '%s 1\n' "$tk_pid" > "$recycled_ticket"
live_ticket="$PNEUMA_GATE_BASE/queue/3-$tk_pid"; bash -c 'source "$1"; printf "%s %s\n" "$2" "$(proc_start "$2")"' _ "$RUNNER" "$tk_pid" > "$live_ticket"
"$RUNNER" janitor >/dev/null 2>&1
check "janitor: removes the queue ticket of a dead runner" test ! -e "$dead_ticket"
check "janitor: removes a queue ticket whose pid was recycled (bare kill -0 would keep it)" test ! -e "$recycled_ticket"
check "janitor: keeps a live runner's queue ticket" test -e "$live_ticket"
kill "$tk_pid" 2>/dev/null; rm -f "$PNEUMA_GATE_BASE"/queue/*

# guard: units whose runner is gone are stopped (the runner's own disk guard dies with a SIGKILL);
# a unit with a live runner, a warm unit and a promote unit are left alone
sleep 300 & gd_pid=$!
bash -c 'source "$1"; state_mark gl-1 "$2" 1 256 admitted' _ "$RUNNER" "$gd_pid"
printf 'pneuma-gate-gl-1.service 1 256\npneuma-gate-orphan-1.service 1 256\npneuma-warm-x-1.service 1 256\npneuma-promote-p-1.service 1 256\n' > "$UNITS_FILE"
: > "$SYSTEMCTL_RECORD"
"$RUNNER" guard >/dev/null 2>&1
check "guard: stops a gate unit whose runner is gone" grep -qx 'stop pneuma-gate-orphan-1.service' "$SYSTEMCTL_RECORD"
check "guard: leaves a unit whose runner is alive" not grep -q 'gl-1' "$SYSTEMCTL_RECORD"
check "guard: leaves warm and promote units alone" bash -c '! grep -q -e warm -e promote "$1"' _ "$SYSTEMCTL_RECORD"
: > "$SYSTEMCTL_RECORD"
PNEUMA_GATE_ABORT_FREE_GIB=99999999 "$RUNNER" guard >/dev/null 2>&1
check "guard: low disk stops every gate unit, including one with a live runner" grep -qx 'stop pneuma-gate-gl-1.service' "$SYSTEMCTL_RECORD"
kill "$gd_pid" 2>/dev/null; : > "$UNITS_FILE"; : > "$SYSTEMCTL_RECORD"; rm -f "$PNEUMA_GATE_STATE_DIR"/runs/*

# per-run loopback route: added before the unit starts, removed when the run ends, swept when stale
check "loopback: a run adds a host route that sources its own address" grep -qE '^route add local 127\.[0-9]+\.[0-9]+\.[0-9]+/32 dev lo scope host src 127\.' "$IP_RECORD"
check "loopback: and removes it afterwards" grep -qE '^route del local 127\.[0-9]+\.[0-9]+\.[0-9]+/32 dev lo' "$IP_RECORD"
: > "$IP_RECORD"
live_lo="$(bash -c 'source "$1"; run_loopback live-keep.0' _ "$RUNNER")"
sleep 300 & lp_pid=$!
bash -c 'source "$1"; state_mark live-keep "$2" 1 256 admitted "$3"' _ "$RUNNER" "$lp_pid" "$live_lo"
printf 'local 127.88.1.1 dev lo scope host src 127.88.1.1\nlocal %s dev lo scope host src %s\nlocal 127.0.0.53 dev lo scope host src 127.0.0.1\nlocal 127.0.0.0/8 dev lo scope host src 127.0.0.1\n' "$live_lo" "$live_lo" > "$IP_ROUTES"
"$RUNNER" janitor >/dev/null 2>&1
check "loopback sweep: a stale per-run route is removed" grep -q '^route del local 127.88.1.1/32' "$IP_RECORD"
check "loopback sweep: a live run's route and the system's own loopback routes are kept" bash -c '! grep -q -e "del local 127.0.0.53" -e "127.0.0.0/8" -e "del local $1/32" "$2"' _ "$live_lo" "$IP_RECORD"
kill "$lp_pid" 2>/dev/null; rm -f "$PNEUMA_GATE_STATE_DIR"/runs/*; : > "$IP_ROUTES"; : > "$IP_RECORD"
ipf_out="$(IP_FAIL=1 "$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1)" && ipf_rc=0 || ipf_rc=$?
check "loopback: if the route cannot be set the run is refused (75), never started without it" bash -c '[ "$1" = 75 ] && grep -q "loopback address" <<<"$2"' _ "$ipf_rc" "$ipf_out"

# network policy: deny by default; only the public internet, the resolvers and ONE per-run loopback
allow="$(bash -c 'source "$1"; net_allow_list 127.77.1.2' _ "$RUNNER")"
allowed_ip() { python3 -c '
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in sys.argv[2].split()) else 1)' "$1" "$allow"; }
check "net: a public address (PyPI-class) is allowed" allowed_ip 151.101.0.223
check "net: the run's own loopback address is allowed" allowed_ip 127.77.1.2
check "net: 127.0.0.1 (k3s API, kubelet, host services) is NOT allowed" not allowed_ip 127.0.0.1
check "net: another run's loopback address is NOT allowed" not allowed_ip 127.77.1.3
for ip in 10.0.0.1 10.42.0.5 172.17.0.1 192.168.1.1 100.64.0.1 169.254.169.254; do
  check "net: private/CGNAT/link-local $ip (wg0, pods, docker, metadata) is NOT allowed" not allowed_ip "$ip"
done
for hostip in $(ip -4 -o addr show | awk '{print $4}' | sed 's#/.*##'); do
  case "$hostip" in 127.*) continue;; esac
  check "net: the host's own address $hostip is NOT allowed (no loop back to host services)" not allowed_ip "$hostip"
done
res="$(awk '$1=="nameserver" && $2 ~ /^[0-9.]+$/ {print $2; exit}' /etc/resolv.conf)"
if [ -n "$res" ]; then check "net: the system DNS resolver $res stays reachable" allowed_ip "$res"; fi
lo1="$(bash -c 'source "$1"; run_loopback a-1' _ "$RUNNER")"; lo2="$(bash -c 'source "$1"; run_loopback b-2' _ "$RUNNER")"
check "net: per-run loopback addresses are 127.x.y.z, not 127.0.0.1, and differ per run" bash -c '[[ "$1" =~ ^127\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$1" != 127.0.0.1 ] && [ "$1" != "$2" ]' _ "$lo1" "$lo2"
check "service: IPAddressDeny=any on the gate unit" grep -q -- "--property=IPAddressDeny=any" "$SCOPE_RECORD"
check "service: IPAddressAllow carries the allow list, without 127.0.0.1/8" bash -c 'grep -q -- "--property=IPAddressAllow=" "$1" && ! grep -q -- "IPAddressAllow=[^ ]*127.0.0.0/8" "$1"' _ "$SCOPE_RECORD"
check "service: the unit gets its own loopback address" grep -q "PNEUMA_GATE_LOOPBACK=127\." "$SCOPE_RECORD"
check "service: the gate state tree is hidden (TemporaryFileSystem over the base and the root state)" bash -c 'grep -q -- "TemporaryFileSystem=$1:ro" "$3" && grep -q -- "TemporaryFileSystem=$2:ro" "$3"' _ "$PNEUMA_GATE_BASE" "$PNEUMA_GATE_STATE_DIR" "$SCOPE_RECORD"
# io cap: the unit disk must resolve to a block device, or the run is refused (never run without the cap)
io_bad_out="$(PNEUMA_GATE_IO_DEVICE=/dev/loop-none bash -c 'source "$1"; unit_props 127.9.9.9; echo "rc=$?"' _ "$RUNNER" 2>&1)"
check "io: an unresolvable device FAILS loudly (rc=1, named), it does not silently drop the cap" bash -c 'grep -q "rc=1" <<<"$1" && grep -q "refusing to run without IOWriteBandwidthMax" <<<"$1"' _ "$io_bad_out"
io_run_out="$(PNEUMA_GATE_IO_DEVICE=/dev/loop-none "$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1)" && io_run_rc=0 || io_run_rc=$?
check "io: a run on a host whose disk does not resolve is refused (75), never started uncapped" bash -c '[ "$1" = 75 ] && grep -q "IOWriteBandwidthMax" <<<"$2"' _ "$io_run_rc" "$io_run_out"
check "io: status says NONE when the cap cannot be applied (the install checks this line)" bash -c 'PNEUMA_GATE_IO_DEVICE=/dev/loop-none "$1" status | grep -q "^io-cap: NONE"' _ "$RUNNER"
check "io: the explicit opt-out is visible in status and in the log" bash -c '"$1" status | grep -q "^io-cap: DISABLED"' _ "$RUNNER"
check "io: the install refuses to finish when status does not show a /dev device" grep -q "io-cap: /dev/" "$REPO_DIR/ci-builder-gate-host.sh"
blk="$(lsblk -dnpo NAME 2>/dev/null | head -1)"
if [ -b "$blk" ]; then
  io_ok="$(PNEUMA_GATE_IO_DEVICE=$blk bash -c 'source "$1"; unit_props 127.9.9.9; printf "%s\n" "${UNIT_PROPS[@]}"' _ "$RUNNER" 2>&1)"
  check "io: a resolving block device puts IOWriteBandwidthMax=<dev> <rate> on the unit" grep -qx -- "--property=IOWriteBandwidthMax=$blk 200M" <<<"$io_ok"
else
  printf 'ok   io: (no block device in this sandbox: the positive case is pinned by the acceptance suite, which requires io.max wbps)\n'
fi

# keep-refs older than two days are pruned from the store
kstore="$PNEUMA_GATE_BASE/repos/fakerepo.git"
git --git-dir="$kstore" update-ref refs/gate-keep/fresh "$head"
old_commit=$(GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" git --git-dir="$kstore" commit-tree "$tree" -m ancient)
git --git-dir="$kstore" update-ref refs/gate-keep/ancient "$old_commit"
"$RUNNER" janitor >/dev/null 2>&1
check "janitor: an old keep-ref no longer pins its objects" bash -c '! git --git-dir="$1" rev-parse -q --verify refs/gate-keep/ancient' _ "$kstore"
check "janitor: a fresh keep-ref is kept" bash -c 'git --git-dir="$1" rev-parse -q --verify refs/gate-keep/fresh' _ "$kstore"

# Forged cores/mem in a run directory never reach admission: the unit's limits do.
mkdir -p "$PNEUMA_GATE_RUN_ROOT/live-1"; printf '64\n' > "$PNEUMA_GATE_RUN_ROOT/live-1/cores"
printf 'pneuma-gate-live-1.service 1 512\n' > "$UNITS_FILE"; printf 'pneuma-gate-live-1.service\n' > "$SYSTEMCTL_ACTIVE"
live_line="$(bash -c 'source "$1"; live_runs' _ "$RUNNER" | grep '^live-1 ')"
check "forged cores/mem: admission reads the unit's configured limits (1 core, 512MB)" test "$live_line" = "live-1 1 512"
: > "$SYSTEMCTL_ACTIVE"; : > "$UNITS_FILE"

# Input limits on the root runner: an oversized bundle and a malformed shallow list are refused.
cap_bundle="$work/cap.bundle"; head -c 4096 /dev/zero > "$cap_bundle"
big_out="$(PNEUMA_GATE_BUNDLE_MAX_MB=0 "$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" --bundle < "$cap_bundle" 2>&1)" && big_rc=0 || big_rc=$?
check "bundle cap: a bundle past the cap is refused (75, named)" bash -c '[ "$1" = 75 ] && grep -q "bundle over" <<<"$2"' _ "$big_rc" "$big_out"
shal_out="$("$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" --shallow 'zzz;rm' 2>&1)" && shal_rc=0 || shal_rc=$?
check "shallow list: anything but 40-hex commits is refused (75)" test "$shal_rc" = 75

# warm-env: the only way an env reaches the shared cache (a run never publishes)
warm_out="$("$RUNNER" warm-env --profile fake --repo fakerepo --ref "$head" 2>&1)" && warm_rc=0 || warm_rc=$?
expect_eq "warm-env: publishes the env for a trusted ref" 0 "$warm_rc"
check "warm-env: the env is in the cache, marked ready, with no writable path" bash -c 'd="$1/envs/fake/fakekey1"; [ -e "$d/.ready" ] && [ -z "$(find "$d" ! -type l -perm /222 | head -1)" ]' _ "$PNEUMA_GATE_BASE"
check "warm-env: built in sandboxed units (the key unit and the build unit)" bash -c 'grep -c -- "--unit=pneuma-warm-" "$1" | grep -qx 2 && grep -q -- "--property=DynamicUser=yes" "$1"' _ "$SCOPE_RECORD"
check "warm-env: the build unit gets the cache slot at the env path (BindPaths)" grep -q -- "--property=BindPaths=.*:$PNEUMA_GATE_ENVS_MOUNT/fakekey1" "$SCOPE_RECORD"
check "warm-env: the build slot is handed to the unit's dynamic uid at its start (ExecStartPre, not a 0777 dir)" grep -q -- "--property=ExecStartPre=+.*chown --reference=$PNEUMA_GATE_RUN_ROOT/warm-" "$SCOPE_RECORD"
check "warm-env: no world-writable slot anywhere in the runner" not grep -q 'chmod 0777' "$RUNNER"
warm_again="$("$RUNNER" warm-env --profile fake --repo fakerepo --ref "$head" 2>&1)"
check "warm-env: idempotent" grep -q 'already published' <<<"$warm_again"
check "warm-env: a ref outside the store is refused" bash -c '! "$1" warm-env --profile fake --repo fakerepo --ref "$2" >/dev/null 2>&1' _ "$RUNNER" "1111111111111111111111111111111111111111"
check "warm-env: a non-hex ref is refused" bash -c '! "$1" warm-env --profile fake --repo fakerepo --ref main >/dev/null 2>&1' _ "$RUNNER"
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null; rm -rf "$PNEUMA_GATE_BASE/envs/fake"; mkdir -p "$PNEUMA_GATE_BASE/envs/fake"
# the proto wheel tag crossing into the root-side stager is validated first
cat > "$work/profiles/tagged.sh" <<'PROFILE'
profile_cores() { echo 1; }
profile_mem_mb() { echo 256; }
profile_env_key() { echo taggedkey; }
profile_wheels_tag() { echo "$(cat "$(dirname "${BASH_SOURCE[0]}")/tag")"; }
profile_stage_root() { echo "$2" >> "$(dirname "${BASH_SOURCE[0]}")/staged"; }
profile_env_build() { mkdir -p "$1"; }
profile_gate() { return 0; }
PROFILE
printf '1.2.3\n' > "$work/profiles/tag"; : > "$work/profiles/staged"
"$RUNNER" warm-env --profile tagged --repo fakerepo --ref "$head" >/dev/null 2>&1
check "warm-env: a validated wheel tag is staged as root, once" test "$(cat "$work/profiles/staged")" = "1.2.3"
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null; rm -rf "$PNEUMA_GATE_BASE/envs/tagged"; mkdir -p "$PNEUMA_GATE_BASE/envs/tagged"; : > "$work/profiles/staged"
printf '1.2.3;touch /tmp/pwn\n' > "$work/profiles/tag"
"$RUNNER" warm-env --profile tagged --repo fakerepo --ref "$head" >/dev/null 2>&1 || true
check "warm-env: a hostile tag from PR content never reaches the root-side stager" test ! -s "$work/profiles/staged"

# ── disk guard: a running gate is stopped when the builder's free space hits the abort line ──
echo 4 > "$work/profiles/sleep"
dg_out="$(PNEUMA_GATE_ABORT_FREE_GIB=99999999 PNEUMA_GATE_DISK_POLL_S=1 "$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1)" && dg_rc=0 || dg_rc=$?
check "disk guard: low free space during a run -> 75 (no verdict), never green" bash -c '[ "$1" = 75 ] && grep -q "builder disk low" <<<"$2"' _ "$dg_rc" "$dg_out"
check "disk guard: the unit is stopped by name" grep -q '^stop pneuma-gate-.*\.service' "$SYSTEMCTL_RECORD"
dg_ok="$(PNEUMA_GATE_ABORT_FREE_GIB=1 PNEUMA_GATE_DISK_POLL_S=1 "$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1)" && dg_ok_rc=0 || dg_ok_rc=$?
expect_eq "disk guard: ample free space leaves the run alone (green)" 0 "$dg_ok_rc"
rm -f "$work/profiles/sleep"; : > "$SYSTEMCTL_RECORD"

# ── engine profile: staged wheels are required, a missing set is no-verdict (75) ──
wh="$work/wheelsfix"; mkdir -p "$wh/tools"; printf 'print("9.9.9")\n' > "$wh/tools/proto_ref.py"
check "engine: profile_wheels_tag reads the proto pin from the checkout" test "$(cd "$wh" && bash -c 'source "$1"; profile_wheels_tag' _ "$ENGINE_PROFILE")" = 9.9.9
bash -c 'cd "$1" && source "$2" && PNEUMA_GATE_WHEELS="$3" profile_env_build "$4"' _ "$wh" "$ENGINE_PROFILE" "$work/nowheels" "$work/envout" >/dev/null 2>&1 && wrc=0 || wrc=$?
expect_eq "engine: proto wheels not staged -> profile_env_build returns 75 (no verdict, not RED)" 75 "$wrc"

# ── engine profile: the root-side wheel stager takes a validated tag and nothing else ──
dk="$work/dockerstub"; mkdir -p "$dk"
cat > "$dk/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$DOCKER_RECORD"
case "$1" in
  create) echo cid123;;
  cp) mkdir -p "${3%/}" && echo wheel > "${3%/}/pneuma_proto-1.0-py3-none-any.whl";;
esac
STUB
chmod +x "$dk/docker"
export DOCKER_RECORD="$work/docker-record.txt"; : > "$DOCKER_RECORD"
PATH="$dk:$PATH" bash -c 'source "$1"; profile_stage_root "$2" 4.5.6' _ "$ENGINE_PROFILE" "$work/stagebase"
check "stage_root: creates the wheel set for the validated tag from the pinned image" bash -c 'grep -q "docker create ghcr.io/deanmak13/pneuma-proto:4.5.6" "$1" && test -d "$2/wheels/pneuma-proto-4.5.6"' _ "$DOCKER_RECORD" "$work/stagebase"
: > "$DOCKER_RECORD"
PATH="$dk:$PATH" bash -c 'source "$1"; profile_stage_root "$2" 4.5.6' _ "$ENGINE_PROFILE" "$work/stagebase"
check "stage_root: an already staged set is left alone (no docker call)" test ! -s "$DOCKER_RECORD"

# ── portal profile: the gate copies the cached trees out of the read-only mount ──
pe="$work/portalenv"; mkdir -p "$pe/trees/web/node_modules/pkg" "$pe/node/bin" "$pe/venv/bin"; echo x > "$pe/trees/web/node_modules/pkg/index.js"
prt="$work/portalrepo"; mkdir -p "$prt/.githooks"; printf '#!/usr/bin/env bash\ntest -f web/node_modules/pkg/index.js\n' > "$prt/.githooks/pre-push"; chmod +x "$prt/.githooks/pre-push"
(cd "$prt" && HOME="$work/ghome" bash -c 'source "$1"; profile_gate "$2" h b 60' _ "$PORTAL_PROFILE" "$pe") > /dev/null 2>&1 && prt_rc=0 || prt_rc=$?
expect_eq "portal gate: node_modules trees are copied into the checkout and the hook runs" 0 "$prt_rc"
check "portal gate: the cache stays untouched (copies, not links)" test "$(stat -c %h "$prt/web/node_modules/pkg/index.js")" = 1

# ── cron and at: only root may schedule work (ITEM 6) ────────────────────────
check "cron/at: the bootstrap restricts both to root (cron.allow and at.allow)" bash -c '
  f="$1"; grep -q "printf .root.*/etc/cron.allow" "$f" && grep -q "printf .root.*/etc/at.allow" "$f"' _ "$REPO_DIR/ci-builder-bootstrap.sh"

# ── live timeout: a hung live run fails the gate (ITEM 4) ─────────────────────
hang_venv="$work/hangvenv"; mkdir -p "$hang_venv/bin"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$hang_venv/bin/python"; chmod +x "$hang_venv/bin/python"
hang_run="$work/hangrun"; mkdir -p "$hang_run"
hang_out=$(cd "$live_repo" && PNEUMA_LIVE_TIMEOUT_S=1 PNEUMA_GATE_RUN_DIR="$hang_run" bash -c 'source "$1"; _engine_run_live "$2"; echo "rc=$?"' _ "$ENGINE_PROFILE" "$hang_venv" 2>&1)
check "live timeout: a hung live run FAILS the gate, promptly" bash -c 'grep -q "timed out" <<<"$1" && grep -q "rc=1" <<<"$1"' _ "$hang_out"

# ── profiles honour the contract the runner depends on ──────────────────────
for p in "$ENGINE_PROFILE" "$PORTAL_PROFILE"; do
  for fn in profile_cores profile_mem_mb profile_env_key profile_env_build profile_gate; do
    check "$(basename "$p"): defines $fn" bash -c "source '$p'; declare -F $fn"
  done
done
check "engine profile: gate is the repo's own pre-push fed the pushed range" grep -q '.githooks/pre-push' "$ENGINE_PROFILE"
check "engine profile: never installs the project editable" not grep -q 'pip.*install.* -e ' "$ENGINE_PROFILE"
check "engine profile: per-run gate lock, not the dev box's" grep -q 'PNEUMA_GATE_LOCK_FILE="\$PNEUMA_GATE_RUN_DIR' "$ENGINE_PROFILE"
check "no credentials in the shipped programs" not grep -qiE '(token|secret|password|ghp_)[a-z_]*=[^ ]' "$RUNNER" "$CLIENT"

# ── GATE-DEDUP-1 at RUNNER level (#20 review): key, ordering, race, submitter, binding ──
# The runner's own functions, sourced alone. Records are written as the runner writes them.
dstore="$work/dwork/.git"
git init -q "$work/dwork"
dgit() { git -C "$work/dwork" -c user.name=t -c user.email=t@t "$@"; }
dgit commit -q --allow-empty -m c1; C1=$(dgit rev-parse HEAD)
dgit commit -q --allow-empty -m c2; C2=$(dgit rev-parse HEAD)
dgit commit -q --allow-empty -m c3; C3=$(dgit rev-parse HEAD)
dgit checkout -q -b diverged "$C1"; dgit commit -q --allow-empty -m x; CX=$(dgit rev-parse HEAD)
dgit checkout -q -
dgit reset -q --hard "$C3"
# one runner function, alone. dedup_admit is the test's name for the admission decision the runner makes in two
# halves (dedup_hold at the worker's start, dedup_decide once the bundle is in the store): both run, in order.
ddo() { bash -c 'source "$1"; shift; dedup_admit() { local id="$1" st="$2" repo="$3" br="$4" hd="$5" sub="$6"; dedup_hold "$id" "$repo" "$br" "$hd" "$sub" "$$" "nonce-$id" "job-$id" || return $?; dedup_decide "$id" "$st" "$repo" "$br" "$hd" "$sub"; }; "$@"' _ "$RUNNER" "$@"; }
rec2() {  # <id> <key> <head> <submitter>: a live run record (its pid is this test shell)
  mkdir -p "$PNEUMA_GATE_DEDUP_DIR"
  printf 'key=%s\nhead=%s\npid=%s\nsubmitter=%s\nunit=pneuma-gate-%s.service\nsuperseded=\n' \
    "$2" "$3" "$$" "$4" "$1" > "$PNEUMA_GATE_DEDUP_DIR/$1"
}
fresh() { rm -rf "$PNEUMA_GATE_DEDUP_DIR"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"; }
SUB_A="dean-devbox"
SUB_B="lane-b"

fresh; rec2 other-repo repoB/main "$C1" "$SUB_A"
ddo dedup_admit n1 "$dstore" repoA main "$C2" "$SUB_A"
check "runner: the same branch name in ANOTHER repo is never cancelled (key is repo + branch)" \
  grep -qx "superseded=" "$PNEUMA_GATE_DEDUP_DIR/other-repo"

fresh; rec2 newer repoA/main "$C3" "$SUB_A"
ddo dedup_admit n2 "$dstore" repoA main "$C2" "$SUB_A"
check "runner: an OLDER commit (after a newer one) never cancels the newer gate" \
  grep -qx "superseded=" "$PNEUMA_GATE_DEDUP_DIR/newer"

fresh; rec2 older repoA/main "$C1" "$SUB_A"
ddo dedup_admit n3 "$dstore" repoA main "$C2" "$SUB_A"
check "runner: a DESCENDANT supersedes the older gate of the same branch and submitter" \
  grep -qx "superseded=$C2" "$PNEUMA_GATE_DEDUP_DIR/older"

fresh; rec2 diverged repoA/main "$CX" "$SUB_A"
div_out="$(ddo dedup_admit n4 "$dstore" repoA main "$C3" "$SUB_A" 2>&1)"
check "runner: diverged heads (a force-push): the newest wins, and it is logged" \
  bash -c 'grep -qx "superseded=$1" "$2/diverged" && grep -q DIVERGE <<<"$3"' _ "$C3" "$PNEUMA_GATE_DEDUP_DIR" "$div_out"

fresh; rec2 theirs repoA/main "$C1" "$SUB_B"
ddo dedup_admit n5 "$dstore" repoA main "$C2" "$SUB_A"
check "runner: a DIFFERENT submitter's same-branch gate is never cancelled" \
  grep -qx "superseded=" "$PNEUMA_GATE_DEDUP_DIR/theirs"

# the race: two simultaneous submissions (C2 and C3) cannot cancel each other; C3 is never cancelled by C2
fresh
ddo dedup_admit race-c2 "$dstore" repoA main "$C2" "$SUB_A" & ddo dedup_admit race-c3 "$dstore" repoA main "$C3" "$SUB_A" &
wait
check "runner: a race between two submissions never cancels the newer head" \
  bash -c 'test -z "$(sed -n "s/^superseded=//p" "$1/race-c3")"' _ "$PNEUMA_GATE_DEDUP_DIR"
# the decision is serialized: while another decision holds the lock, this one waits
fresh
exec 7>"$PNEUMA_GATE_DEDUP_DIR/.lock"; flock 7
ddo dedup_admit lock-test "$dstore" repoA main "$C2" "$SUB_A" & lock_pid=$!
sleep 2
check "runner: a submission waits while another decision holds the root lock" kill -0 "$lock_pid"
flock -u 7; exec 7>&-; wait "$lock_pid" 2>/dev/null || true

# fairness: submitter A at its cap is refused; submitter B is still admitted; neither cancels the other
fresh
rec2 a-1 repoA/q1 "$C1" "$SUB_A"; rec2 a-2 repoA/q2 "$C1" "$SUB_A"; rec2 a-3 repoA/q3 "$C1" "$SUB_A"
rc_capped=0; ddo dedup_admit flood-a "$dstore" repoA main "$C2" "$SUB_A" || rc_capped=$?
check "fairness: a submitter at its cap is refused (exit 2), not queued" test "$rc_capped" = 2
rc_b=0; ddo dedup_admit b-1 "$dstore" repoA main "$C2" "$SUB_B" || rc_b=$?
check "fairness: another submitter is still admitted while A is at its cap" test "$rc_b" = 0
check "fairness: A's flood cancels none of B's gates, and B's gate is recorded" \
  bash -c 'test -f "$1/b-1" && ! grep -q "^superseded=." "$1/b-1"' _ "$PNEUMA_GATE_DEDUP_DIR"
rec_entry_out="$(SSH_ORIGINAL_COMMAND="run --profile fake --submitter evil --repo x" PNEUMA_GATE_RUNNER_BIN="$work/bin/argv-recorder" "$ENTRY" --submitter test-lane 2>&1)" && rec_entry_rc=0 || rec_entry_rc=$?
check "identity: a client cannot pass --submitter in its command (forgery refused)" \
  bash -c '[ "$1" = 75 ] && grep -q "option .--submitter. is not allowed" <<<"$2"' _ "$rec_entry_rc" "$rec_entry_out"
SSH_ORIGINAL_COMMAND="run --profile fake --repo fakerepo --head $head --base $base --tree $tree" \
  PNEUMA_GATE_RUNNER_BIN="$work/bin/argv-recorder" SSH_USER_AUTH=/tmp/forged-auth "$ENTRY" --submitter test-lane >/dev/null 2>&1 || true
check "identity: the runner is called with the forced submitter, whatever the environment says" \
  grep -q -- "--submitter test-lane" "$work/argv-recorded.txt"
check "identity: an entry with no forced submitter refuses to run anything" \
  bash -c 'SSH_ORIGINAL_COMMAND="status" "$1" >/dev/null 2>&1; test $? = 75' _ "$ENTRY"
check "identity: the runner refuses a run with no submitter identity" \
  bash -c '"$1" run --profile fake --repo fakerepo --head "$2" --base "$3" --tree "$4" >/dev/null 2>&1; test $? = 75' _ "$RUNNER" "$head" "$base" "$tree"
check "grammar: an unknown verb is refused" \
  bash -c 'SSH_ORIGINAL_COMMAND="rm -rf /" "$1" --submitter test-lane >/dev/null 2>&1; test $? = 75' _ "$ENTRY"
check "grammar: shell metacharacters are refused, never run" \
  bash -c 'SSH_ORIGINAL_COMMAND="status; touch $2/pwned" "$1" --submitter test-lane >/dev/null 2>&1; test ! -e "$2/pwned"' _ "$ENTRY" "$work"
check "grammar: an option outside the allowlist is refused" \
  bash -c 'SSH_ORIGINAL_COMMAND="run --profile fake --evil yes" "$1" --submitter test-lane >/dev/null 2>&1; test $? = 75' _ "$ENTRY"
check "grammar: a value outside its pattern is refused (a non-hex head)" \
  bash -c 'SSH_ORIGINAL_COMMAND="run --profile fake --head notahash" "$1" --submitter test-lane >/dev/null 2>&1; test $? = 75' _ "$ENTRY"
check "elevation: the entry runs EXACTLY the runner as root (sudo -n -- <runner> ...), nothing else" \
  bash -c 'SSH_ORIGINAL_COMMAND="status" PNEUMA_GATE_RUNNER_BIN="$2" "$1" --submitter test-lane >/dev/null 2>&1; grep -q "^-n -- $2 status --submitter test-lane$" "$3"' _ "$ENTRY" "$work/bin/argv-recorder" "$SUDO_RECORD"
check "traversal: the entry itself refuses '..' in --repo (its own message, not the pattern's)" \
  bash -c 'out=$(SSH_ORIGINAL_COMMAND="have --repo a..b" "$1" --submitter test-lane 2>&1); test $? = 75; grep -q "contains .\.\.." <<<"$out"' _ "$ENTRY"
check "traversal: the entry itself refuses '..' in --branch (its own message)" \
  bash -c 'out=$(SSH_ORIGINAL_COMMAND="run --profile fake --branch a..b" "$1" --submitter test-lane 2>&1); test $? = 75; grep -q "contains .\.\.." <<<"$out"' _ "$ENTRY"
check "elevation: the runner refuses a sudo caller other than pneuma-submit" \
  bash -c 'SUDO_USER=mallory "$1" status >/dev/null 2>&1; test $? = 75' _ "$RUNNER"
check "identity: an unknown entry argument is refused" \
  bash -c 'SSH_ORIGINAL_COMMAND="status" "$1" --evil yes >/dev/null 2>&1; test $? = 75' _ "$ENTRY"
check "grammar: the runner's bare name as the first word is accepted and stripped" \
  bash -c 'SSH_ORIGINAL_COMMAND="pneuma-gate-runner run --profile fake" PNEUMA_GATE_RUNNER_BIN="$3" "$1" --submitter test-lane >/dev/null 2>&1; grep -q "^run --submitter test-lane --profile fake$" "$4"' _ "$ENTRY" "$RUNNER" "$work/bin/argv-recorder" "$ARGV_RECORD"
check "grammar: have takes a bare list of commit SHAs and nothing else" \
  bash -c 'SSH_ORIGINAL_COMMAND="have --repo fakerepo $2 $3" PNEUMA_GATE_RUNNER_BIN="$4" "$1" --submitter test-lane >/dev/null 2>&1; grep -q "^have --submitter test-lane --repo fakerepo $2 $3$" "$5"' _ "$ENTRY" "$head" "$base" "$work/bin/argv-recorder" "$ARGV_RECORD"
check "grammar: status is accepted with no options" \
  bash -c 'SSH_ORIGINAL_COMMAND="status" PNEUMA_GATE_RUNNER_BIN="$2" "$1" --submitter test-lane >/dev/null 2>&1; grep -q "^status --submitter test-lane$" "$3"' _ "$ENTRY" "$work/bin/argv-recorder" "$ARGV_RECORD"
check "identity: a forced submitter must look like an identifier" \
  bash -c 'SSH_ORIGINAL_COMMAND="status" "$1" --submitter "../evil" >/dev/null 2>&1; test $? = 75' _ "$ENTRY"

# the bundle binds the claim: it must carry the repo and branch at the head being gated
dgit update-ref refs/pneuma-gate/repo/repoA "$C2"
dgit update-ref refs/pneuma-gate/branch/main "$C2"
dgit bundle create "$work/bind.bundle" refs/pneuma-gate/repo/repoA refs/pneuma-gate/branch/main >/dev/null 2>&1
check "bundle: a bundle carrying the claimed repo and branch at the head binds" \
  ddo bundle_binds "$work/bind.bundle" repoA main "$C2"
check "bundle: a bundle whose branch is not the claimed one does NOT bind" \
  not ddo bundle_binds "$work/bind.bundle" repoA other "$C2"
mkdir -p "$work/brokenwt" && echo "gitdir: $work/nonexistent/worktrees/x" > "$work/brokenwt/.git"
check "bundle: it binds from ANY working directory, even one with a broken worktree .git (the container case)" \
  bash -c 'cd "$3" && bash -c "source \"$1\"; bundle_binds \"$2\" repoA main \"$4\""' _ "$RUNNER" "$work/bind.bundle" "$work/brokenwt" "$C2"
check "bundle: a claimed head the bundle does not carry does NOT bind" \
  not ddo bundle_binds "$work/bind.bundle" repoA main "$C3"

# ════ security review of 175dee9: one test per finding, each fails without its fix ════
# ── AUTHORIZATION ──
# A1. a submitter that came through sudo may run only have / run / status
for verb in janitor guard warm-env unit promote warm-unit nonsense; do
  a1_out="$(SUDO_USER=pneuma-submit "$RUNNER" "$verb" 2>&1)" && a1_rc=0 || a1_rc=$?
  check "A1: through sudo the verb '$verb' is refused (75), the sudoers rule's three verbs only" bash -c '[ "$1" = 75 ] && grep -q "not available through the submit path" <<<"$2"' _ "$a1_rc" "$a1_out"
done
check "A1: through sudo, status is still served" bash -c 'SUDO_USER=pneuma-submit "$1" status | grep -q "^host="' _ "$RUNNER"

# A2. the submitter's cap is enforced BEFORE the runner reads the bundle, promotes it, claims a loopback
# address or touches the store: an over-cap submitter costs the host nothing
mkdir -p "$PNEUMA_GATE_DEDUP_DIR"; rm -f "$PNEUMA_GATE_DEDUP_DIR"/*
sleep 300 & cap_pid=$!
for n in 1 2 3; do
  bash -c 'source "$1"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"; printf "key=\nhead=%s\npid=%s\npstart=%s\nsubmitter=capped\nunit=pneuma-gate-cap-%s.service\nsuperseded=\n" "$3" "$2" "$(proc_start "$2")" "$4" > "$PNEUMA_GATE_DEDUP_DIR/cap-$4"' _ "$RUNNER" "$cap_pid" "$head" "$n"
done
: > "$SCOPE_RECORD"; : > "$IP_RECORD"; ls "$PNEUMA_GATE_STATE_DIR/in" > "$work/in-before.txt"
git init -q --bare "$work/cap-bundle-src.git" 2>/dev/null
a2_out="$("$RUNNER" run --submitter capped --profile fake --repo capfresh --head "$head" --base "$base" --tree "$tree" --bundle < /dev/null 2>&1)" && a2_rc=0 || a2_rc=$?
check "A2: a submitter at its cap is refused (75, named)" bash -c '[ "$1" = 75 ] && grep -q "already holds" <<<"$2"' _ "$a2_rc" "$a2_out"
check "A2: ...before any promote unit ran" bash -c '! grep -q -- "--unit=pneuma-promote-" "$1"' _ "$SCOPE_RECORD"
check "A2: ...before a loopback address was claimed" bash -c '! grep -q "route add local" "$1"' _ "$IP_RECORD"
check "A2: ...before a bundle was staged" bash -c 'ls "$1/in" | cmp -s - "$2"' _ "$PNEUMA_GATE_STATE_DIR" "$work/in-before.txt"
check "A2: ...and before the object store for the repo was created" test ! -d "$PNEUMA_GATE_BASE/repos/capfresh.git"
check "A2: another submitter is not blocked by that cap" bash -c '"$1" run --submitter other-lane --profile fake --repo fakerepo --head "$2" --base "$3" --tree "$4" >/dev/null 2>&1; test $? = 0' _ "$RUNNER" "$head" "$base" "$tree"
kill "$cap_pid" 2>/dev/null; rm -f "$PNEUMA_GATE_DEDUP_DIR"/*

# A3. the claimed names are compared as fixed strings, and a bad branch is refused before anything is staged
dgit update-ref refs/pneuma-gate/repo/aXb "$C2"
dgit update-ref refs/pneuma-gate/branch/mainX "$C2"
dgit bundle create "$work/regex.bundle" refs/pneuma-gate/repo/aXb refs/pneuma-gate/branch/mainX >/dev/null 2>&1
check "A3: a claimed repo 'a.b' does NOT bind to a bundle carrying 'aXb' (no pattern matching)" \
  not ddo bundle_binds "$work/regex.bundle" a.b mainX "$C2"
check "A3: a claimed branch 'main.' does NOT bind to 'mainX'" \
  not ddo bundle_binds "$work/regex.bundle" aXb main. "$C2"
check "A3: the exact names still bind" ddo bundle_binds "$work/regex.bundle" aXb mainX "$C2"
# the call site, not only the function: a run whose bundle does not carry the claimed repo/branch is
# refused by cmd_run itself (75, named), and one that does carry it gets past the binding
bind_bad="$("$RUNNER" run --submitter bind-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" --branch other --bundle < "$work/bind.bundle" 2>&1)" && bind_bad_rc=0 || bind_bad_rc=$?
check "B: cmd_run refuses a bundle that does not carry the claimed repo and branch (75, named)" bash -c '[ "$1" = 75 ] && grep -q "does not carry" <<<"$2"' _ "$bind_bad_rc" "$bind_bad"
bind_ok="$("$RUNNER" run --submitter bind-lane --profile fake --repo aXb --head "$C2" --base "$C2" --tree "$(dgit rev-parse "$C2^{tree}")" --branch mainX --bundle < "$work/regex.bundle" 2>&1)" || true
check "B: ...and the same call with names the bundle does carry gets past the binding" bash -c '! grep -q "does not carry" <<<"$1" && grep -q "gate for aXb branch mainX" <<<"$1"' _ "$bind_ok"
check "B: a claimed repo that merely pattern-matches the bundle's is refused at the call site too" bash -c 'out="$("$1" run --submitter bind-lane --profile fake --repo "a.b" --head "$2" --base "$2" --tree "$3" --branch mainX --bundle < "$4" 2>&1)"; grep -q "does not carry" <<<"$out"' _ "$RUNNER" "$C2" "$(dgit rev-parse "$C2^{tree}")" "$work/regex.bundle"
: > "$SCOPE_RECORD"
a3_out="$("$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" --branch 'a..b' --bundle < "$work/regex.bundle" 2>&1)" && a3_rc=0 || a3_rc=$?
check "A3: an invalid branch is refused up front (75), before a bundle is staged or promoted" bash -c '[ "$1" = 75 ] && grep -q "bad branch name" <<<"$2" && ! grep -q "pneuma-promote" "$3"' _ "$a3_rc" "$a3_out" "$SCOPE_RECORD"

# A4. liveness by pid + start time: a recycled pid is not a live gate (it would lock a submitter out)
sleep 300 & rc_pid=$!
fresh
for n in 1 2 3; do
  printf 'key=\nhead=%s\npid=%s\npstart=1\nsubmitter=recyc\nunit=pneuma-gate-rc-%s.service\nsuperseded=\n' "$C1" "$rc_pid" "$n" > "$PNEUMA_GATE_DEDUP_DIR/rc-$n"
done
rc_a4=0; ddo dedup_hold new-a4 repoA main "$C2" recyc "$$" nonce-a4 job-a4 || rc_a4=$?
check "A4: records whose pid was recycled (start time differs) do not count toward the cap" test "$rc_a4" = 0
printf 'key=\nhead=%s\npid=%s\npstart=%s\nsubmitter=live\nunit=pneuma-gate-lv.service\nsuperseded=\n' "$C1" "$rc_pid" "$(bash -c 'source "$1"; proc_start "$2"' _ "$RUNNER" "$rc_pid")" > "$PNEUMA_GATE_DEDUP_DIR/lv-1"
check "A4: a record whose runner is the same live process counts" bash -c 'source "$1"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"; [ "$(dedup_count_submitter live)" = 1 ]' _ "$RUNNER"
kill "$rc_pid" 2>/dev/null; fresh

# ── NETWORK POLICY ──
net_list() { PNEUMA_GATE_RESOLV_CONFS="$1" bash -c 'source "$1"; net_allow_list 127.77.1.2' _ "$RUNNER"; }
in_list() { python3 -c '
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in sys.argv[2].split()) else 1)' "$1" "$2"; }
# N1. a resolver on 127.0.0.1 (or any non-stub loopback) would open every host-local service: never allowed
printf 'nameserver 127.0.0.1\nnameserver 127.0.0.2\nnameserver 127.0.0.53\nnameserver 8.8.4.4\nnameserver 2001:4860:4860::8888\n' > "$work/resolv-a.conf"
# the host's address list is scripted WITHOUT lo, so the loopback rule is what must exclude them (not "it is a local address")
printf '2: eth0    inet 192.0.2.50/24 brd 192.0.2.255 scope global eth0\n' > "$IP_ADDRS"
n1="$(net_list "$work/resolv-a.conf")"; : > "$IP_ADDRS"
check "N1: a resolver on 127.0.0.1 is NOT allowed (DNS fails loudly rather than opening the k3s API)" not in_list 127.0.0.1 "$n1"
check "N1: nor any other loopback address (127.0.0.2)" not in_list 127.0.0.2 "$n1"
check "N1: the systemd-resolved stub 127.0.0.53 (DNS only) is allowed" in_list 127.0.0.53 "$n1"
check "N1: a remote resolver is allowed" in_list 8.8.4.4 "$n1"
check "N1: an IPv6 resolver adds nothing (no IPv6 in the allow list at all: IPv6 is denied)" bash -c '! grep -q : <<<"$1"' _ "$n1"
printf 'nameserver 10.99.7.7\n' > "$IP_ADDRS"; printf '2: eth0    inet 10.99.7.7/24 brd 10.99.7.255 scope global eth0\n' > "$IP_ADDRS"
printf 'nameserver 10.99.7.7\nnameserver 203.0.113.9\n' > "$work/resolv-b.conf"
n1b="$(net_list "$work/resolv-b.conf")"
check "N1: a resolver that is one of THIS host's own addresses is NOT allowed" not in_list 10.99.7.7 "$n1b"
check "N1: a resolver elsewhere is" in_list 203.0.113.9 "$n1b"
# N2. a point-to-point address line ("peer") must not break the list, and its peer is excluded too
printf '3: tun0    inet 10.9.0.1 peer 198.51.100.77/32 scope global tun0\n4: eth1    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth1\n' > "$IP_ADDRS"
n2="$(net_list "$work/resolv-a.conf")"; n2_rc=$?
check "N2: an address line with a peer does not fail the list" test "$n2_rc" = 0 -a -n "$n2"
check "N2: the peer address of a tunnel is excluded" not in_list 198.51.100.77 "$n2"
check "N2: the host's own non-private address is excluded" not in_list 192.0.2.10 "$n2"
check "N2: its neighbours stay allowed (public egress works)" in_list 198.51.100.78 "$n2"
: > "$IP_ADDRS"
# N3. two runs can never hold the same loopback address: the claim retries on a collision
first_lo="$(bash -c 'source "$1"; run_loopback coll-1.0' _ "$RUNNER")"
printf '%s\n' "$first_lo" > "$IP_EXISTS"; : > "$IP_RECORD"
got_lo="$(bash -c 'source "$1"; loopback_claim coll-1' _ "$RUNNER")"
check "N3: a taken loopback address is skipped, another one is claimed and routed" bash -c '[ -n "$1" ] && [ "$1" != "$2" ] && grep -q "route add local $1/32" "$3"' _ "$got_lo" "$first_lo" "$IP_RECORD"
for i in 0 1 2 3 4 5 6 7; do bash -c 'source "$1"; run_loopback "coll-2.$2"; echo' _ "$RUNNER" "$i"; done > "$IP_EXISTS"
check "N3: when every candidate is taken the claim FAILS (the run is refused, never shares an address)" bash -c '! bash -c "source \"$1\"; loopback_claim coll-2" _ "$RUNNER"' _ "$RUNNER"
: > "$IP_EXISTS"
# N4. every unit class carries the policy: gate, warm (key and build) get deny-by-default; promote has no network
# earlier sections leave submitter records behind; a clean state keeps this gate from being refused at its cap
rm -rf "$PNEUMA_GATE_DEDUP_DIR"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"; : > "$SYSTEMCTL_ACTIVE"
: > "$SCOPE_RECORD"
# the bundle the client ships always carries the repo's own keep ref (the fetch is repo-scoped and strict)
git -C "$src" update-ref refs/pneuma-gate/repo/fakerepo "$head"; git -C "$src" bundle create "$work/n4.bundle" refs/pneuma-gate/repo/fakerepo >/dev/null 2>&1
"$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" --bundle < "$work/n4.bundle" >/dev/null 2>&1 || true
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null; rm -rf "$PNEUMA_GATE_BASE/envs/fake"; mkdir -p "$PNEUMA_GATE_BASE/envs/fake"
"$RUNNER" warm-env --profile fake --repo fakerepo --ref "$head" >/dev/null 2>&1 || true
all_units="$(grep -o -- '--unit=[^ ]*' "$SCOPE_RECORD" | sort -u | wc -l)"
denied="$(grep -c -- '--property=IPAddressDeny=any' "$SCOPE_RECORD")"
promoted="$(grep -c -- '--property=PrivateNetwork=yes' "$SCOPE_RECORD")"
check "N4: every systemd-run in the runner either denies the network by default or has none (units seen: $all_units)" test "$all_units" = "$((denied + promoted))"
check "N4: at least one gate unit and the warm units were among them" test "$denied" -ge 3
check "N4: no systemd-run in the runner is launched without the policy properties (static)" bash -c '
  n=$(grep -c "\$SYSTEMD_RUN_BIN\" --unit=" "$1"); m=$(grep -c "\"\${UNIT_PROPS\[@\]}\"\|PrivateNetwork=yes" "$1"); [ "$n" -le "$m" ]' _ "$RUNNER"
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null; rm -rf "$PNEUMA_GATE_BASE/envs/fake"; mkdir -p "$PNEUMA_GATE_BASE/envs/fake"
check "N4: the loopback pool is never 127.0.0.1" bash -c 'for i in $(seq 1 300); do a="$(source "$1"; run_loopback "id-$i")"; [ "$a" != 127.0.0.1 ] && [[ "$a" =~ ^127\.(1[6-9]|[2-9][0-9]|1[0-9][0-9]|2[01][0-9])\. ]] || exit 1; done' _ "$RUNNER"


# ════ capacity-cap bypass / fail-open liveness: unknown is OCCUPIED, only positive proof of death frees ════
fresh_state() { rm -rf "$PNEUMA_GATE_STATE_DIR/runs" "$PNEUMA_GATE_STATE_DIR/in"; mkdir -p "$PNEUMA_GATE_STATE_DIR/runs" "$PNEUMA_GATE_STATE_DIR/in"; : > "$UNITS_FILE"; : > "$SYSTEMCTL_ACTIVE"; }
admit_one() {  # → can_admit for a 2-core job with MAX_CONCURRENT=1 on an idle 8-core host
  printf 'MemAvailable: %d kB\n' $((64 * 1024 * 1024)) > "$work/cf-mem"; printf '0.1 1 1 1/1 1\n' > "$work/cf-load"
  PNEUMA_GATE_MAX_CONCURRENT=1 PNEUMA_GATE_NPROC=8 PNEUMA_GATE_MEMINFO="$work/cf-mem" PNEUMA_GATE_LOADAVG="$work/cf-load" \
    PNEUMA_GATE_RESERVE_MEM_MB=0 bash -c 'source "$1"; can_admit 2 512' _ "$RUNNER"
}
sleep 300 & cf_pid=$!
cf_start="$(bash -c 'source "$1"; proc_start "$2"' _ "$RUNNER" "$cf_pid")"

# F1. a reservation whose runner cannot be examined holds its slot
fresh_state
check "F1: baseline: with nothing running a job is admitted" admit_one
printf 'pid=nonsense\npstart=1\ncores=2\nmem_mb=512\nstate=admitted\n' > "$PNEUMA_GATE_STATE_DIR/runs/f1-garbage"
check "F1: a marker with an unparseable pid keeps the slot (the next job is NOT admitted past MAX_CONCURRENT)" not admit_one
fresh_state; printf 'pid=%s\npstart=\ncores=2\nmem_mb=512\nstate=admitted\n' "$cf_pid" > "$PNEUMA_GATE_STATE_DIR/runs/f1-nostart"
check "F1: a live pid with no recorded start time keeps the slot" not admit_one
fresh_state; printf 'garbage with no keys at all\n' > "$PNEUMA_GATE_STATE_DIR/runs/f1-junk"
check "F1: a marker with no fields keeps the slot" not admit_one
fresh_state; printf 'pid=999999\npstart=7\ncores=2\nmem_mb=512\nstate=admitted\n' > "$PNEUMA_GATE_STATE_DIR/runs/f1-dead"
check "F1: a runner that is positively dead (pid not in /proc) releases the slot" admit_one
fresh_state; printf 'pid=%s\npstart=1\ncores=2\nmem_mb=512\nstate=admitted\n' "$cf_pid" > "$PNEUMA_GATE_STATE_DIR/runs/f1-recycled"
check "F1: a recycled pid (same pid, other start time) is positive proof of death" admit_one
fresh_state; printf 'pid=%s\npstart=%s\ncores=2\nmem_mb=512\nstate=admitted\n' "$cf_pid" "$cf_start" > "$PNEUMA_GATE_STATE_DIR/runs/f1-live"
check "F1: a live runner keeps its slot" not admit_one
fresh_state; printf 'pid=nonsense\npstart=1\ncores=x\nmem_mb=512\nstate=admitted\n' > "$PNEUMA_GATE_STATE_DIR/runs/f1-badcores"
check "F1: an unreadable weight is charged as the whole host" bash -c 'source "$1"; PNEUMA_GATE_NPROC=8 live_runs | grep -x "f1-badcores 8 512" >/dev/null' _ "$RUNNER"

# F2. the janitor reclaims ONLY on positive proof of death
fresh_state
printf 'pid=nonsense\npstart=1\ncores=2\nmem_mb=512\nstate=admitted\n' > "$PNEUMA_GATE_STATE_DIR/runs/f2-unknown"
printf 'pid=999999\npstart=7\ncores=2\nmem_mb=512\nstate=admitted\n' > "$PNEUMA_GATE_STATE_DIR/runs/f2-dead"
printf 'pid=999998\npstart=7\ncores=2\nmem_mb=512\nstate=admitted\n' > "$PNEUMA_GATE_STATE_DIR/runs/f2-dead-unit-active"
: > "$PNEUMA_GATE_STATE_DIR/in/f2-unknown.bundle"; : > "$PNEUMA_GATE_STATE_DIR/in/f2-orphan-999996.bundle"
printf 'pneuma-gate-f2-dead-unit-active.service\n' > "$SYSTEMCTL_ACTIVE"
"$RUNNER" janitor >/dev/null 2>&1
check "F2: a marker whose runner cannot be examined is NOT reclaimed" test -e "$PNEUMA_GATE_STATE_DIR/runs/f2-unknown"
check "F2: a positively dead runner with no unit is reclaimed" test ! -e "$PNEUMA_GATE_STATE_DIR/runs/f2-dead"
check "F2: a dead runner whose unit is still active is NOT reclaimed" test -e "$PNEUMA_GATE_STATE_DIR/runs/f2-dead-unit-active"
printf 'pid=999997\npstart=7\ncores=2\nmem_mb=512\nstate=admitted\n' > "$PNEUMA_GATE_STATE_DIR/runs/f2-dead-unit-unknown"
SYSTEMCTL_IS_ACTIVE_BROKEN=1 "$RUNNER" janitor >/dev/null 2>&1
check "F2: a dead runner whose unit state cannot be read is NOT reclaimed" test -e "$PNEUMA_GATE_STATE_DIR/runs/f2-dead-unit-unknown"
check "F2: an orphan bundle is reclaimed only with proof (runner dead, unit inactive)" test ! -e "$PNEUMA_GATE_STATE_DIR/in/f2-orphan-999996.bundle"
check "F2: a bundle whose marker is unreadable is kept" test -e "$PNEUMA_GATE_STATE_DIR/in/f2-unknown.bundle"

# F3. systemctl failing is not "no units running"
fresh_state
check "F3: the live-run listing FAILS when systemctl does" bash -c 'SYSTEMCTL_FAIL=1 bash -c "source \"$1\"; ! live_runs >/dev/null 2>&1" _ "$1"' _ "$RUNNER"
admit_one_fail() { SYSTEMCTL_FAIL=1 admit_one; }
check "F3: admission refuses when the units cannot be listed" not admit_one_fail
# there is no queue timeout (a queued job waits for capacity): bounded here by `timeout`, and the detached worker is reaped
f3_out="$(SYSTEMCTL_FAIL=1 PNEUMA_GATE_POLL_S=1 timeout 4 "$RUNNER" run --submitter test-lane-f3 --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1)" && f3_rc=0 || f3_rc=$?
pkill -f 'submitter test-lane-f3' 2>/dev/null || true
check "F3: a run with an unlistable host waits (no queue timeout) and is never started blind" bash -c '[ "$1" = 124 ] && ! grep -q "launching unit" <<<"$2"' _ "$f3_rc" "$f3_out"
printf 'pneuma-gate-f3-weird.service - -\n' > "$UNITS_FILE"; printf 'pneuma-gate-f3-weird.service\n' > "$SYSTEMCTL_ACTIVE"
check "F3: a running unit whose quota cannot be read is charged as the whole host" bash -c 'source "$1"; PNEUMA_GATE_NPROC=8 live_runs | grep -x "f3-weird 8 0" >/dev/null' _ "$RUNNER"
fresh_state
check "F3: an unreadable load average counts as saturated (a second gate is not stacked)" bash -c '
  printf "pneuma-gate-f3-a.service 1 256\n" > "$UNITS_FILE"; printf "pneuma-gate-f3-a.service\n" > "$SYSTEMCTL_ACTIVE"
  printf "MemAvailable: %d kB\n" $((64*1024*1024)) > "$1/m"
  ! PNEUMA_GATE_MAX_CONCURRENT=4 PNEUMA_GATE_NPROC=8 PNEUMA_GATE_MEMINFO="$1/m" PNEUMA_GATE_LOADAVG="$1/no-such-loadavg" PNEUMA_GATE_RESERVE_MEM_MB=0 bash -c "source \"$2\"; can_admit 2 512"' _ "$work" "$RUNNER"
fresh_state

# F4. the guard stops a unit only when its runner is POSITIVELY dead
printf 'pneuma-gate-f4-unknown.service 1 256\npneuma-gate-f4-dead.service 1 256\n' > "$UNITS_FILE"
printf 'pid=nonsense\npstart=1\ncores=1\nmem_mb=256\nstate=admitted\n' > "$PNEUMA_GATE_STATE_DIR/runs/f4-unknown"
printf 'pid=999995\npstart=7\ncores=1\nmem_mb=256\nstate=admitted\nnonce=n-f4-dead\n' > "$PNEUMA_GATE_STATE_DIR/runs/f4-dead"
printf 'pneuma-gate-f4-dead.service n-f4-dead\n' > "$UNIT_NONCES"
: > "$SYSTEMCTL_RECORD"; "$RUNNER" guard >/dev/null 2>&1
check "F4: guard stops the unit of a positively dead runner" grep -qx 'stop pneuma-gate-f4-dead.service' "$SYSTEMCTL_RECORD"
check "F4: guard leaves the unit of a runner it cannot examine (it may be a healthy gate)" bash -c '! grep -q f4-unknown "$1"' _ "$SYSTEMCTL_RECORD"
fresh_state; : > "$SYSTEMCTL_RECORD"

# F5. the per-submitter cap counts records whose liveness is unknown, and never deletes or supersedes them
fresh
for n in 1 2 3; do printf 'key=\nhead=%s\npid=nonsense\npstart=1\nsubmitter=unk\nunit=pneuma-gate-unk-%s.service\nsuperseded=\n' "$C1" "$n" > "$PNEUMA_GATE_DEDUP_DIR/unk-$n"; done
f5_rc=0; ddo dedup_hold f5-new repoA main "$C2" unk "$$" nonce-f5 job-f5 || f5_rc=$?
check "F5: three records of unknown liveness hold the submitter at its cap (a fourth gate is refused, exit 2)" test "$f5_rc" = 2
fresh
printf 'key=repoA/main\nhead=%s\npid=nonsense\npstart=1\nsubmitter=%s\nunit=pneuma-gate-f5-unk.service\nsuperseded=\n' "$C1" "$SUB_A" > "$PNEUMA_GATE_DEDUP_DIR/f5-unk"
ddo dedup_admit f5-newer "$dstore" repoA main "$C2" "$SUB_A" >/dev/null 2>&1
check "F5: an unknown-liveness record is neither deleted nor superseded by a newer head" bash -c 'test -f "$1/f5-unk" && grep -qx "superseded=" "$1/f5-unk"' _ "$PNEUMA_GATE_DEDUP_DIR"
fresh
printf 'key=repoA/main\nhead=%s\npid=999994\npstart=7\nsubmitter=%s\nunit=pneuma-gate-f5-dead.service\nsuperseded=\n' "$C1" "$SUB_A" > "$PNEUMA_GATE_DEDUP_DIR/f5-dead"
ddo dedup_admit f5-newer2 "$dstore" repoA main "$C2" "$SUB_A" >/dev/null 2>&1
check "F5: a record whose runner and unit are both positively gone is dropped" test ! -e "$PNEUMA_GATE_DEDUP_DIR/f5-dead"
fresh
printf 'key=repoA/main\nhead=%s\npid=999993\npstart=7\nsubmitter=%s\nunit=pneuma-gate-f5-dead-active.service\nsuperseded=\n' "$C1" "$SUB_A" > "$PNEUMA_GATE_DEDUP_DIR/f5-dead-active"
printf 'pneuma-gate-f5-dead-active.service\n' > "$SYSTEMCTL_ACTIVE"
f5b="$(ddo dedup_count_submitter "$SUB_A")"
check "F5: a record whose runner is dead but whose unit is active still counts" test "$f5b" = 1
: > "$SYSTEMCTL_ACTIVE"; fresh

# F6. a queue ticket that cannot be examined is neither deleted nor treated as the head
printf 'garbage\n' > "$PNEUMA_GATE_BASE/queue/1-unk"
"$RUNNER" janitor >/dev/null 2>&1
check "F6: an unparseable ticket is kept by the janitor" test -e "$PNEUMA_GATE_BASE/queue/1-unk"
check "F6: ...and is never the head of the queue" bash -c 'source "$1"; [ "$(first_live_waiter)" != 1-unk ]' _ "$RUNNER"
rm -f "$PNEUMA_GATE_BASE"/queue/*; kill "$cf_pid" 2>/dev/null


# ════ stale identity mappings: every binding carries the run's nonce, verified at use, released on proof of end ════
# S1. the guard stops a unit for a dead runner only when the unit carries that reservation's nonce
fresh_state
printf 'pneuma-gate-s1-recycled.service 1 256\npneuma-gate-s1-match.service 1 256\npneuma-gate-s1-nomarker.service 1 256\n' > "$UNITS_FILE"
printf 'pid=999990\npstart=7\ncores=1\nmem_mb=256\nstate=admitted\nnonce=nonce-A\n' > "$PNEUMA_GATE_STATE_DIR/runs/s1-recycled"
printf 'pid=999991\npstart=7\ncores=1\nmem_mb=256\nstate=admitted\nnonce=nonce-M\n' > "$PNEUMA_GATE_STATE_DIR/runs/s1-match"
printf 'pneuma-gate-s1-recycled.service nonce-B\npneuma-gate-s1-match.service nonce-M\npneuma-gate-s1-nomarker.service nonce-Z\n' > "$UNIT_NONCES"
: > "$SYSTEMCTL_RECORD"; "$RUNNER" guard >/dev/null 2>&1
check "S1: a unit under a RECYCLED name (another run's nonce) is NOT stopped for a dead reservation" bash -c '! grep -q s1-recycled "$1"' _ "$SYSTEMCTL_RECORD"
check "S1: the unit that carries the reservation's nonce is stopped" grep -qx 'stop pneuma-gate-s1-match.service' "$SYSTEMCTL_RECORD"
check "S1: a unit with no reservation at all (unaccounted capacity) is stopped" grep -qx 'stop pneuma-gate-s1-nomarker.service' "$SYSTEMCTL_RECORD"
fresh_state; : > "$UNIT_NONCES"

# S2. supersession stops a unit only when the record's nonce matches the unit's
fresh
printf 'pneuma-gate-s2-old.service 1 256\n' > "$UNITS_FILE"; printf 'pneuma-gate-s2-old.service\n' > "$SYSTEMCTL_ACTIVE"
printf 'key=repoA/main\nhead=%s\npid=%s\npstart=%s\nsubmitter=%s\nunit=pneuma-gate-s2-old.service\nnonce=nonce-A\nsuperseded=\n' "$C1" "$$" "$(bash -c 'source "$1"; proc_start "$2"' _ "$RUNNER" "$$")" "$SUB_A" > "$PNEUMA_GATE_DEDUP_DIR/s2-old"
printf 'pneuma-gate-s2-old.service nonce-B\n' > "$UNIT_NONCES"; : > "$SYSTEMCTL_RECORD"
ddo dedup_admit s2-new "$dstore" repoA main "$C2" "$SUB_A" >/dev/null 2>&1
check "S2: a recycled unit name (nonce differs) is NOT stopped by a record that names it" bash -c '! grep -q s2-old "$1"' _ "$SYSTEMCTL_RECORD"
fresh
printf 'key=repoA/main\nhead=%s\npid=%s\npstart=%s\nsubmitter=%s\nunit=pneuma-gate-s2-old.service\nnonce=nonce-A\nsuperseded=\n' "$C1" "$$" "$(bash -c 'source "$1"; proc_start "$2"' _ "$RUNNER" "$$")" "$SUB_A" > "$PNEUMA_GATE_DEDUP_DIR/s2-old"
printf 'pneuma-gate-s2-old.service nonce-A\n' > "$UNIT_NONCES"; : > "$SYSTEMCTL_RECORD"
ddo dedup_admit s2-new2 "$dstore" repoA main "$C2" "$SUB_A" >/dev/null 2>&1
check "S2: the unit that carries the record's nonce is stopped" grep -qx 'stop pneuma-gate-s2-old.service' "$SYSTEMCTL_RECORD"
fresh; : > "$UNIT_NONCES"; : > "$SYSTEMCTL_ACTIVE"; : > "$UNITS_FILE"

# S3. a run releases its bindings (reservation, submitter record, loopback address, bundle) ONLY on proof its unit is gone
s3() {  # <active|inactive|broken>
  fresh_state; fresh
  : > "$IP_RECORD"; : > "$SYSTEMCTL_ACTIVE"
  [ "$1" = active ] && printf 'pneuma-gate-s3-run.service\n' > "$SYSTEMCTL_ACTIVE"
  printf 'pid=%s\npstart=1\ncores=1\nmem_mb=256\nstate=admitted\nloopback=127.66.1.1\nnonce=nonce-S3\n' "$$" > "$PNEUMA_GATE_STATE_DIR/runs/s3-run"
  printf 'key=\nhead=%s\npid=%s\npstart=1\nsubmitter=s3\nunit=pneuma-gate-s3-run.service\nnonce=nonce-S3\nsuperseded=\n' "$C1" "$$" > "$PNEUMA_GATE_DEDUP_DIR/s3-run"
  : > "$PNEUMA_GATE_STATE_DIR/in/s3-run.bundle"
  SYSTEMCTL_IS_ACTIVE_BROKEN=$([ "$1" = broken ] && echo 1 || echo 0) bash -c 'source "$1"; RUN_ID=s3-run; UNIT=pneuma-gate-s3-run; DEDUP_ID=s3-run; LOOPBACK=127.66.1.1; BUNDLE_FILE="$STATE_DIR/in/s3-run.bundle"; cleanup' _ "$RUNNER" >/dev/null 2>&1
}
s3 active
check "S3: while its unit is still active the run keeps its reservation, record, bundle..." bash -c 'test -e "$1/runs/s3-run" -a -e "$1/in/s3-run.bundle" -a -e "$2/s3-run"' _ "$PNEUMA_GATE_STATE_DIR" "$PNEUMA_GATE_DEDUP_DIR"
check "S3: ...and its loopback address is NOT released (no route deletion)" bash -c '! grep -q "route del local 127.66.1.1" "$1"' _ "$IP_RECORD"
s3 broken
check "S3: a unit whose state cannot be read counts as not gone: nothing is released" bash -c 'test -e "$1/runs/s3-run" -a -e "$2/s3-run"' _ "$PNEUMA_GATE_STATE_DIR" "$PNEUMA_GATE_DEDUP_DIR"
s3 inactive
check "S3: once the unit is positively inactive everything is released" bash -c 'test ! -e "$1/runs/s3-run" -a ! -e "$1/in/s3-run.bundle" -a ! -e "$2/s3-run" && grep -q "route del local 127.66.1.1" "$3"' _ "$PNEUMA_GATE_STATE_DIR" "$PNEUMA_GATE_DEDUP_DIR" "$IP_RECORD"

# S4. a loopback address stays bound while any reservation names it, even one whose runner is dead; a claim of a bound
# address is refused (the recycled-address case); it frees only after the reservation goes on proof of death
fresh_state; : > "$IP_RECORD"; : > "$IP_EXISTS"
printf 'local 127.67.1.1 dev lo scope host src 127.67.1.1\n' > "$IP_ROUTES"
printf 'pid=999989\npstart=7\ncores=1\nmem_mb=256\nstate=admitted\nloopback=127.67.1.1\nnonce=nonce-S4\n' > "$PNEUMA_GATE_STATE_DIR/runs/s4-old"
printf 'pneuma-gate-s4-old.service\n' > "$SYSTEMCTL_ACTIVE"
"$RUNNER" janitor >/dev/null 2>&1
check "S4: a dead runner whose unit is still active keeps its reservation AND its address" bash -c 'test -e "$1/runs/s4-old" && ! grep -q "route del local 127.67.1.1" "$2"' _ "$PNEUMA_GATE_STATE_DIR" "$IP_RECORD"
printf '127.67.1.1\n' > "$IP_EXISTS"
claimed="$(bash -c 'source "$1"; run_loopback() { echo 127.67.1.1; }; loopback_claim s4-new' _ "$RUNNER")" && claim_rc=0 || claim_rc=$?
check "S4: the bound address cannot be handed to a new run (the claim is refused)" bash -c '[ "$1" != 0 ] && [ -z "$2" ]' _ "$claim_rc" "$claimed"
: > "$SYSTEMCTL_ACTIVE"; "$RUNNER" janitor >/dev/null 2>&1
check "S4: after the unit is gone the reservation is reclaimed and the address released" bash -c 'test ! -e "$1/runs/s4-old" && grep -q "route del local 127.67.1.1" "$2"' _ "$PNEUMA_GATE_STATE_DIR" "$IP_RECORD"
: > "$IP_EXISTS"; : > "$IP_ROUTES"; fresh_state

# S5. the janitor reclaims dead submitter records and stale warm slots only on proof
fresh
printf 'key=\nhead=%s\npid=999988\npstart=7\nsubmitter=s5\nunit=pneuma-gate-s5-dead.service\nsuperseded=\n' "$C1" > "$PNEUMA_GATE_DEDUP_DIR/s5-dead"
printf 'key=\nhead=%s\npid=nonsense\npstart=7\nsubmitter=s5\nunit=pneuma-gate-s5-unk.service\nsuperseded=\n' "$C1" > "$PNEUMA_GATE_DEDUP_DIR/s5-unk"
mkdir -p "$PNEUMA_GATE_BASE/envs/fake/.slot-warm-1-1" "$PNEUMA_GATE_BASE/envs/fake/.slot-warm-2-2"
printf 'pneuma-warm-warm-2-2-build.service\n' > "$SYSTEMCTL_ACTIVE"
"$RUNNER" janitor >/dev/null 2>&1
check "S5: a submitter record with runner and unit positively gone is reclaimed" test ! -e "$PNEUMA_GATE_DEDUP_DIR/s5-dead"
check "S5: a record of unknown liveness is kept" test -e "$PNEUMA_GATE_DEDUP_DIR/s5-unk"
check "S5: a stale warm slot (no live runner, units inactive) is reclaimed" test ! -d "$PNEUMA_GATE_BASE/envs/fake/.slot-warm-1-1"
check "S5: a slot whose build unit is still active is kept" test -d "$PNEUMA_GATE_BASE/envs/fake/.slot-warm-2-2"
rmdir "$PNEUMA_GATE_BASE/envs/fake/.slot-warm-2-2"; : > "$SYSTEMCTL_ACTIVE"; fresh

# S6. the warm slot is frozen into the shared cache only if ONE dynamic uid owns every path
slot_check() { bash -c 'source "$1"; slot_uids() { printf "%s\n" $UIDS; }; slot_owned_by_one_dynamic_uid /x' _ "$RUNNER"; }
check "S6: a slot owned by one uid in the dynamic range is accepted" env UIDS="61500" PNEUMA_GATE_DYNAMIC_UID_MIN=61184 PNEUMA_GATE_DYNAMIC_UID_MAX=65519 bash -c "$(declare -f slot_check); RUNNER='$RUNNER'; slot_check"
check "S6: a path of a second uid (a recycled uid wrote here) refuses the freeze" not env UIDS="61500 61501" PNEUMA_GATE_DYNAMIC_UID_MIN=61184 PNEUMA_GATE_DYNAMIC_UID_MAX=65519 bash -c "$(declare -f slot_check); RUNNER='$RUNNER'; slot_check"
check "S6: a uid outside the dynamic range (a real user) refuses the freeze" not env UIDS="1000" PNEUMA_GATE_DYNAMIC_UID_MIN=61184 PNEUMA_GATE_DYNAMIC_UID_MAX=65519 bash -c "$(declare -f slot_check); RUNNER='$RUNNER'; slot_check"
check "S6: an empty slot listing refuses the freeze" not env UIDS="" PNEUMA_GATE_DYNAMIC_UID_MIN=61184 PNEUMA_GATE_DYNAMIC_UID_MAX=65519 bash -c "$(declare -f slot_check); RUNNER='$RUNNER'; slot_check"

# S7. the cluster that answers on the DSN must be THIS run's (nonce set at start, verified before use)
cat > "$pgstub/psql" <<'STUB'
#!/usr/bin/env bash
[ "${PG_STUB_PSQL_FAIL:-0}" = 1 ] && exit 2
echo "${PG_STUB_SERVER_NONCE:-}"
STUB
chmod +x "$pgstub/psql"
pg_case nonce-ok
s7_ok=$(PNEUMA_GATE_NONCE=run-n-1 PG_STUB_SERVER_NONCE=run-n-1 PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2"; echo "rc=$?"; _engine_pg_down' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "S7: a server that answers with this run's nonce is used" bash -c 'grep -q "rc=0" <<<"$1" && grep -q "pneuma.run_nonce=run-n-1" "$2"' _ "$s7_ok" "$PG_STUB_CALLS"
pg_case nonce-bad
s7_bad=$(PNEUMA_GATE_NONCE=run-n-1 PG_STUB_SERVER_NONCE=another-run PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2"; echo "rc=$?"' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "S7: a server on the recycled address that carries another run's nonce is REFUSED (rc=1, named)" bash -c 'grep -q "rc=1" <<<"$1" && grep -q "does not carry this run" <<<"$1"' _ "$s7_bad"
check "S7: ...and the cluster that was started is stopped" grep -q "pg_ctl -D $PGRUN/pg/data -m immediate -w stop" "$PG_STUB_CALLS"
pg_case nonce-none
s7_none=$(PNEUMA_GATE_NONCE=run-n-1 PG_STUB_SERVER_NONCE= PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2"; echo "rc=$?"' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "S7: a server that answers with no nonce (some other cluster) is refused" grep -q "rc=1" <<<"$s7_none"
pg_case nonce-unit
s7_unit=$(PNEUMA_GATE_REMOTE_RUN=1 PATH="$pgstub:$PATH" PNEUMA_GATE_PG_BIN="$pgstub" bash -c 'source "$1"; _engine_pg_up "$2"; echo "rc=$?"' _ "$ENGINE_PROFILE" "$PGRUN" 2>&1)
check "S7: inside a gate unit a missing nonce is a refusal, never a pass" bash -c 'grep -q "rc=1" <<<"$1" && grep -q "no run nonce" <<<"$1"' _ "$s7_unit"
check "S7: a unit gets a nonce on its command line (the thing the guard and supersession verify)" grep -q "PNEUMA_GATE_NONCE=" "$SCOPE_RECORD"


# ── GATE-QUEUE-1: detached jobs, re-attach, cancel, a queue that never expires ─────────────
# Helpers run the runner's own functions (sourced), as the dedup tests above do.
lj() { bash -c 'source "$1"; live_job_for_key "$2"' _ "$RUNNER" "$1"; }   # lj <jobkey>: the live job with exactly that key
jk() { bash -c 'source "$1"; shift; job_key "$@"' _ "$RUNNER" "$@"; }   # jk <repo> <head> <tree> <submitter> <profile> <base> <origin_main> <env>
as_sub() {   # as_sub <submitter> <cancel args...>: the runner's cmd_cancel, as that submitter
  local who="$1"; shift
  bash -c 'source "$1"; SUBMITTER="$2"; shift 2; cmd_cancel "$@"' _ "$RUNNER" "$who" "$@"
}
rec3() {  # rec3 <id> <key> <head> <submitter> <jobkey>: a live record that carries its scope key
  mkdir -p "$PNEUMA_GATE_DEDUP_DIR"
  printf 'key=%s\nhead=%s\npid=%s\nsubmitter=%s\nunit=pneuma-gate-%s.service\njobkey=%s\nsuperseded=\n' \
    "$2" "$3" "$$" "$4" "$1" "$5" > "$PNEUMA_GATE_DEDUP_DIR/$1"
}
T2="$(dgit rev-parse "$C2^{tree}")"
K0="$(jk repoA "$C2" "$T2" "$SUB_A" fake "$C1" "$C1" "")"
rm -rf "$PNEUMA_GATE_DEDUP_DIR"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"
rec3 job-a "repoA/main" "$C2" "$SUB_A" "$K0"
check "attach: the job with EXACTLY this scope key is found" \
  bash -c 'test "$1" = job-a' _ "$(lj "$K0")"
check "attach: a different submitter (a different key) is NOT attached to" \
  bash -c 'test -z "$1"' _ "$(lj "$(jk repoA "$C2" "$T2" "$SUB_B" fake "$C1" "$C1" "")")"
check "attach: a different profile is NOT attached to" \
  bash -c 'test -z "$1"' _ "$(lj "$(jk repoA "$C2" "$T2" "$SUB_A" other "$C1" "$C1" "")")"
check "attach: a different base is NOT attached to" \
  bash -c 'test -z "$1"' _ "$(lj "$(jk repoA "$C2" "$T2" "$SUB_A" fake "$C3" "$C1" "")")"
check "attach: a different origin-main is NOT attached to" \
  bash -c 'test -z "$1"' _ "$(lj "$(jk repoA "$C2" "$T2" "$SUB_A" fake "$C1" "$C3" "")")"
check "attach: a different scope env flag (PNEUMA_PREPUSH_FULL) is NOT attached to" \
  bash -c 'test -z "$1"' _ "$(lj "$(jk repoA "$C2" "$T2" "$SUB_A" fake "$C1" "$C1" "PNEUMA_PREPUSH_FULL=1")")"
check "attach: another repo, or another head, is NOT attached to" \
  bash -c 'test -z "$1" -a -z "$2"' _ "$(lj "$(jk otherrepo "$C2" "$T2" "$SUB_A" fake "$C1" "$C1" "")")" "$(lj "$(jk repoA "$C3" "$T2" "$SUB_A" fake "$C1" "$C1" "")")"
check "attach: a record with no job key (a legacy record) is never attached to" \
  bash -c 'test -z "$1"' _ "$(lj "")"
sed -i 's/^superseded=$/superseded=newer/' "$PNEUMA_GATE_DEDUP_DIR/job-a"
check "attach: a superseded job is never attached to" \
  bash -c 'test -z "$1"' _ "$(lj "$K0")"
check "scope key: every scope field changes the key (repo, head, tree, submitter, profile, base, origin-main, env)" \
  bash -c 'n=$(printf "%s\n" "$@" | sort -u | wc -l); test "$n" = 9' _ "$K0" \
    "$(jk otherrepo "$C2" "$T2" "$SUB_A" fake "$C1" "$C1" "")" "$(jk repoA "$C3" "$T2" "$SUB_A" fake "$C1" "$C1" "")" \
    "$(jk repoA "$C2" "$C3" "$SUB_A" fake "$C1" "$C1" "")" "$(jk repoA "$C2" "$T2" "$SUB_B" fake "$C1" "$C1" "")" \
    "$(jk repoA "$C2" "$T2" "$SUB_A" other "$C1" "$C1" "")" "$(jk repoA "$C2" "$T2" "$SUB_A" fake "$C3" "$C1" "")" \
    "$(jk repoA "$C2" "$T2" "$SUB_A" fake "$C1" "$C3" "")" "$(jk repoA "$C2" "$T2" "$SUB_A" fake "$C1" "$C1" "PNEUMA_PREPUSH_FULL=1")"
check "scope key: the same scope always yields the same key" \
  bash -c 'test "$1" = "$2"' _ "$K0" "$(jk repoA "$C2" "$T2" "$SUB_A" fake "$C1" "$C1" "")"

# cancel: only the caller's own live jobs for that repo and head; the unit is stopped
rm -rf "$PNEUMA_GATE_DEDUP_DIR"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"; : > "$SYSTEMCTL_RECORD"
rec2 job-c "repoA/main" "$C2" "$SUB_A"
# the owner's cancel stops the unit only when the unit carries the record's nonce (guarded identity)
printf 'nonce=nonce-c\n' >> "$PNEUMA_GATE_DEDUP_DIR/job-c"
printf 'pneuma-gate-job-c.service nonce-c\n' > "$UNIT_NONCES"
as_sub "$SUB_B" --repo repoA --head "$C2" >/dev/null 2>&1
check "cancel: another submitter cannot cancel this job" \
  grep -qx "superseded=" "$PNEUMA_GATE_DEDUP_DIR/job-c"
as_sub "$SUB_A" --repo repoA --head "$C2" >/dev/null 2>&1
check "cancel: the submitter cancels its own job (superseded=cancelled-by-submitter)" \
  grep -qx "superseded=cancelled-by-submitter" "$PNEUMA_GATE_DEDUP_DIR/job-c"
check "cancel: the job's unit is stopped by name" \
  grep -qx "stop pneuma-gate-job-c.service" "$SYSTEMCTL_RECORD"
check "cancel: a malformed head is refused" \
  bash -c 'source "$1"; SUBMITTER=x; ! cmd_cancel --repo repoA --head nope >/dev/null 2>&1' _ "$RUNNER"
check "grammar: cancel is accepted with --repo and --head" \
  bash -c 'SSH_ORIGINAL_COMMAND="cancel --repo fakerepo --head $2" PNEUMA_GATE_RUNNER_BIN="$3" "$1" --submitter test-lane >/dev/null 2>&1; grep -q "^cancel --submitter test-lane --repo fakerepo --head $2$" "$4"' _ "$ENTRY" "$head" "$work/bin/argv-recorder" "$ARGV_RECORD"

# a newer head on the same branch auto-cancels the QUEUED older job; the queued job then refuses at admission
rm -rf "$PNEUMA_GATE_DEDUP_DIR"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"
rec2 job-q "repoA/main" "$C2" "$SUB_A"
ddo dedup_admit job-new "$dstore" repoA main "$C3" "$SUB_A" >/dev/null 2>&1
check "newer head: the older QUEUED job is superseded by the descendant head" \
  grep -qx "superseded=$C3" "$PNEUMA_GATE_DEDUP_DIR/job-q"
printf 'MemAvailable: 90000000 kB\n' > "$work/qmeminfo"; printf '0.10 0.10 0.10 1/100 1\n' > "$work/qloadavg"
qadmit_rc=0
qadmit_out="$(env PNEUMA_GATE_BASE="$work/qbase" PNEUMA_GATE_NPROC=64 PNEUMA_GATE_RESERVE_MEM_MB=0 PNEUMA_GATE_MEMINFO="$work/qmeminfo" \
  PNEUMA_GATE_LOADAVG="$work/qloadavg" bash -c 'source "$1"; DEDUP_ID=job-q; mkdir -p "$PNEUMA_GATE_BASE/queue" "$PNEUMA_GATE_BASE/runs"; admit 1 100' _ "$RUNNER" 2>&1)" || qadmit_rc=$?
check "newer head: the superseded QUEUED job refuses at admission (exit 75, names the superseder)" \
  bash -c 'test "$1" = 75 && grep -q "superseded by" <<<"$2"' _ "$qadmit_rc" "$qadmit_out"

# the queue never expires: with NO capacity and the old 2s timeout set, the wait outlives it
rm -rf "$work/qbase"; mkdir -p "$work/qbase/queue" "$work/qbase/runs"
env PNEUMA_GATE_BASE="$work/qbase" PNEUMA_GATE_MAX_CONCURRENT=0 PNEUMA_GATE_QUEUE_TIMEOUT_S=2 PNEUMA_GATE_POLL_S=1 \
  bash -c 'source "$1"; admit 1 100' _ "$RUNNER" >/dev/null 2>&1 &
qwait=$!
sleep 6
if kill -0 "$qwait" 2>/dev/null; then qalive=yes; else qalive=no; fi
kill "$qwait" 2>/dev/null || true; wait "$qwait" 2>/dev/null || true
expect_eq "queue: a waiting gate is still queued after the old 2s timeout (it never expires)" yes "$qalive"

# a detached job outlives its connection: the client is killed mid-gate; a same-head submission re-attaches
rm -rf "$PNEUMA_GATE_DEDUP_DIR" "$PNEUMA_GATE_BASE/jobs"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"
echo 6 > "$work/profiles/sleep"
# the client's stream is a PIPE: killing its reader is a dropped connection (the job's next write hits a broken pipe)
"$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" --branch main 2>&1 | exec cat > "$work/dropA.out" &
dropA=$!
for _ in $(seq 1 30); do ls "$PNEUMA_GATE_DEDUP_DIR"/* >/dev/null 2>&1 && break; sleep 1; done
# kill the reader only, and do not wait: the runner exits by itself at its next write, the job does not
kill -9 "$dropA" 2>/dev/null || true
"$RUNNER" run --submitter test-lane --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" --branch main > "$work/attachB.out" 2>&1; rcB=$?
rm -f "$work/profiles/sleep"
check "detached: the job survives its connection being killed (the re-attach gets a green verdict)" \
  bash -c 'test "$1" = 0' _ "$rcB"
check "detached: the re-submission attached to the live job instead of queueing again" \
  grep -q "attached to live job" "$work/attachB.out"
check "detached: the attached client receives the verdict line" \
  grep -q "^PNEUMA_GATE_RESULT .*exit=0" "$work/attachB.out"
expect_eq "detached: exactly one job ran for the two submissions" 1 "$(find "$PNEUMA_GATE_BASE/jobs" -mindepth 1 -maxdepth 1 | wc -l)"

# the janitor reaps an old job log only when its job is gone; the dispatch runs cancel and refuses an unknown verb
mkdir -p "$PNEUMA_GATE_BASE/jobs/old-dead" "$PNEUMA_GATE_BASE/jobs/old-live"
touch -d '10 days ago' "$PNEUMA_GATE_BASE/jobs/old-dead" "$PNEUMA_GATE_BASE/jobs/old-live"
rm -rf "$PNEUMA_GATE_DEDUP_DIR"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"
printf 'key=repoA/main\nhead=%s\npid=%s\nsubmitter=x\nunit=none\nsuperseded=\n' "$C2" "$$" > "$PNEUMA_GATE_DEDUP_DIR/old-live"
bash -c 'source "$1"; cmd_janitor' _ "$RUNNER" >/dev/null 2>&1 || true
check "janitor: reaps an old job log whose job is gone" test ! -e "$PNEUMA_GATE_BASE/jobs/old-dead"
check "janitor: keeps an old job log whose job is still live" test -e "$PNEUMA_GATE_BASE/jobs/old-live"
check "dispatch: the cancel verb runs for an identified submitter" \
  bash -c 'out="$("$1" cancel --submitter test-lane --repo fakerepo --head "$2" 2>&1)" && grep -q "^cancelled 0 job" <<<"$out"' _ "$RUNNER" "$head"
check "dispatch: an unknown verb is refused with usage (exit 2)" \
  bash -c '"$1" bogus --submitter test-lane >/dev/null 2>&1; test $? = 2' _ "$RUNNER"

# the verdict's root-owned result file is authoritative: a forged log line cannot change an attach's exit
rf_exit() { bash -c 'source "$1"; job_exit "$2"' _ "$RUNNER" "$1"; }
mkdir -p "$PNEUMA_GATE_RESULTS_DIR" "$PNEUMA_GATE_BASE/jobs/rf-1" "$PNEUMA_GATE_BASE/jobs/rf-2"
printf 'PNEUMA_GATE_RESULT repo=x exit=1 elapsed=1s host=h\n' > "$PNEUMA_GATE_RESULTS_DIR/rf-1"
printf 'PNEUMA_GATE_RESULT repo=x exit=0 elapsed=1s host=h\n' > "$PNEUMA_GATE_BASE/jobs/rf-1/log"
check "verdict: the exit comes from the result file, not from a forged green log line" \
  bash -c 'test "$1" = 1' _ "$(rf_exit rf-1)"
printf 'PNEUMA_GATE_RESULT repo=x exit=0 elapsed=1s host=h\n' > "$PNEUMA_GATE_BASE/jobs/rf-2/log"
check "verdict: a job with a green log line but NO result file is never green (75)" \
  bash -c 'test "$1" = 75' _ "$(rf_exit rf-2)"
jid_of_e2e="$(basename "$(dirname "$(ls -d "$PNEUMA_GATE_BASE"/jobs/[0-9]*/log | head -1)")")"   # real job ids start with a timestamp
check "verdict: the line the attached client received is the job's result file, verbatim" \
  bash -c 'grep -qxF "$(cat "$2/$3")" "$1"' _ "$work/attachB.out" "$PNEUMA_GATE_RESULTS_DIR" "$jid_of_e2e"
check "job log is 0640 (the submitter group reads it; nobody else does)" \
  bash -c 'test "$(stat -c %a "$1")" = 640' _ "$PNEUMA_GATE_BASE/jobs/$jid_of_e2e/log"

# the client verifies EVERY field of the verdict against the submission, and the job key that binds them
VERDICT_BIN="$work/bin/verdict-runner"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$VERDICT_LINE"' 'exit 0' > "$VERDICT_BIN"; chmod +x "$VERDICT_BIN"
om="$base"                                   # the client's origin-main: the fixture's origin/main is the base
vj() { jk fakerepo "$head" "$tree" "${1:-test-lane}" "${2:-fake}" "$base" "$om" ""; }
vline() {  # vline <submitter> <profile> <base> <origin_main> <env> <jobkey>
  printf 'PNEUMA_GATE_RESULT repo=fakerepo head=%s tree=%s profile=%s base=%s origin_main=%s env=%s submitter=%s jobkey=%s exit=0 elapsed=1s host=fakehost' \
    "$head" "$tree" "$2" "$3" "$4" "$5" "$1" "$6"
}
client_rc() {  # client_rc <verdict line>: the client's exit for a run whose verdict is this line
  local rc=0
  VERDICT_LINE="$1" PNEUMA_GATE_RUNNER="$VERDICT_BIN" "$CLIENT" --repo-dir "$src" --profile fake --head "$head" --base "$base" \
    --log-dir "$work/logs-verdict" >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
expect_eq "verdict: a fully consistent verdict for this scope is green (exit 0)" 0 \
  "$(client_rc "$(vline test-lane fake "$base" "$om" "" "$(vj)")")"
expect_eq "verdict: a different PROFILE is refused (75)" 75 \
  "$(client_rc "$(vline test-lane other "$base" "$om" "" "$(vj test-lane other)")")"
expect_eq "verdict: a different BASE is refused (75)" 75 \
  "$(client_rc "$(vline test-lane fake "$C3" "$om" "" "$(jk fakerepo "$head" "$tree" test-lane fake "$C3" "$om" "")")")"
expect_eq "verdict: a different ORIGIN-MAIN is refused (75)" 75 \
  "$(client_rc "$(vline test-lane fake "$base" "$C3" "" "$(jk fakerepo "$head" "$tree" test-lane fake "$base" "$C3" "")")")"
expect_eq "verdict: a different scope ENV flag is refused (75)" 75 \
  "$(client_rc "$(vline test-lane fake "$base" "$om" "PNEUMA_PREPUSH_FULL=1" "$(jk fakerepo "$head" "$tree" test-lane fake "$base" "$om" "PNEUMA_PREPUSH_FULL=1")")")"
expect_eq "verdict: a job key that does not bind the fields is refused (75)" 75 \
  "$(client_rc "$(vline test-lane fake "$base" "$om" "" "0000000000000000000000000000000000000000000000000000000000000000")")"
expect_eq "verdict: a SUBMITTER field that does not match the job key is refused (75)" 75 \
  "$(client_rc "$(vline other-lane fake "$base" "$om" "" "$(vj)")")"

# the keep-ref fetch is FORCED: a head that is NOT a descendant of the last keep value (a sibling, a rebase) is
# accepted and the keep ref follows it. A non-forced refspec rejects it as non-fast-forward (the P0 outage).
kstore="$work/keepstore.git"; git init -q --bare "$kstore"
dgit push -q "$kstore" "$C2:refs/gate-keep/repo/repoK"
dgit update-ref refs/pneuma-gate/repo/repoK "$CX"
dgit bundle create "$work/keep.bundle" refs/pneuma-gate/repo/repoK >/dev/null 2>&1
dgit update-ref -d refs/pneuma-gate/repo/repoK
kfetch_ok() {
  ddo fetch_keep_refs "$kstore" "$work/keep.bundle" repoK "" >/dev/null 2>&1 \
    && [ "$(git --git-dir="$kstore" rev-parse refs/gate-keep/repo/repoK)" = "$CX" ]
}
check "keep refs: a non-descendant head is fetched and the keep ref follows it (forced refspec)" kfetch_ok

# SCOPE: a bundle names other repos' refs too; the keep fetch only ever writes THIS repo's keep refs.
dgit update-ref refs/pneuma-gate/repo/repoK "$CX"
dgit update-ref refs/pneuma-gate/repo/otherrepo "$C3"
dgit bundle create "$work/scope.bundle" refs/pneuma-gate/repo/repoK refs/pneuma-gate/repo/otherrepo >/dev/null 2>&1
dgit update-ref -d refs/pneuma-gate/repo/repoK; dgit update-ref -d refs/pneuma-gate/repo/otherrepo
scope_ok() {
  ddo fetch_keep_refs "$kstore" "$work/scope.bundle" repoK "" >/dev/null 2>&1 \
    && [ -z "$(git --git-dir="$kstore" for-each-ref refs/gate-keep/repo/otherrepo)" ] \
    && [ "$(git --git-dir="$kstore" rev-parse refs/gate-keep/repo/repoK)" = "$CX" ]
}
check "keep scope: a bundle's refs for ANOTHER repo are never written; this repo's keep ref is" scope_ok

# ════ VM17 third pass (a): an ssh disconnect never costs the job, queued or running ════
# The detached worker owns the job. The ssh-attached parent only tails the log and ignores HUP, TERM and INT, so a
# dropped connection or a stray signal to the parent leaves the worker, its record, its queue ticket and its verdict alone.
sig_ignored() {  # <pid> <mask>: 0 when every signal bit in the mask is ignored by that process (HUP=1 INT=2 TERM=0x4000)
  local m; m="$(awk '/^SigIgn:/ {print $2}' "/proc/$1/status" 2>/dev/null)"
  [[ "$m" =~ ^[0-9a-f]+$ ]] || return 1
  (( (16#$m & $2) == $2 ))
}
rec_of() {  # <submitter>: the id of a run record that submitter holds (empty until one exists)
  local f; for f in "$PNEUMA_GATE_DEDUP_DIR"/*; do [ -f "$f" ] && grep -qx "submitter=$1" "$f" && { basename "$f"; return 0; }; done
  return 0
}
rec_field() { sed -n "s/^$2=//p" "$PNEUMA_GATE_DEDUP_DIR/$1" | head -1; }   # <id> <field>
HUP_INT_TERM=16387   # 0x4003

# (a1) queued: capacity is zero, so the job waits in the queue while the parent is signalled
rm -rf "$PNEUMA_GATE_DEDUP_DIR" "$PNEUMA_GATE_BASE/jobs" "$PNEUMA_GATE_BASE/queue"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR" "$PNEUMA_GATE_BASE/queue"
PNEUMA_GATE_MAX_CONCURRENT=0 PNEUMA_GATE_POLL_S=1 "$RUNNER" run --submitter test-lane-dq --profile fake --repo fakerepo \
  --head "$head" --base "$base" --tree "$tree" --branch main > "$work/dq.out" 2>&1 &
dq=$!
for _ in $(seq 1 30); do [ -n "$(rec_of test-lane-dq)" ] && break; sleep 1; done
dqid="$(rec_of test-lane-dq)"; dqw="$(rec_field "$dqid" pid)"
kill -HUP "$dq" 2>/dev/null; kill -TERM "$dq" 2>/dev/null; kill -INT "$dq" 2>/dev/null
sleep 2
check "disconnect (queued): the parent ignores HUP, TERM and INT" sig_ignored "$dq" "$HUP_INT_TERM"
check "disconnect (queued): the parent survives the signals" kill -0 "$dq"
check "disconnect (queued): the detached worker survives the parent's signals" kill -0 "$dqw"
check "disconnect (queued): the run record and the queue ticket are retained" \
  bash -c 'test -e "$1/$2" && test -n "$(ls "$3"/queue 2>/dev/null)"' _ "$PNEUMA_GATE_DEDUP_DIR" "$dqid" "$PNEUMA_GATE_BASE"
kill -TERM "$dqw" 2>/dev/null; wait "$dq" 2>/dev/null || true   # the test's own teardown of the queued worker (its abandon path)

# (a2) running: the job holds capacity and runs (6s profile); the parent is signalled mid-gate
rm -rf "$PNEUMA_GATE_DEDUP_DIR" "$PNEUMA_GATE_BASE/jobs" "$PNEUMA_GATE_BASE/queue"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR" "$PNEUMA_GATE_BASE/queue"
echo 6 > "$work/profiles/sleep"
"$RUNNER" run --submitter test-lane-dr --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" \
  --branch main > "$work/dr.out" 2>&1 &
dr=$!
for _ in $(seq 1 30); do [ -n "$(rec_of test-lane-dr)" ] && break; sleep 1; done
drid="$(rec_of test-lane-dr)"; drw="$(rec_field "$drid" pid)"
kill -HUP "$dr" 2>/dev/null; kill -TERM "$dr" 2>/dev/null; kill -INT "$dr" 2>/dev/null
check "disconnect (running): the parent ignores HUP, TERM and INT" sig_ignored "$dr" "$HUP_INT_TERM"
check "disconnect (running): the running worker is not stopped by the parent's signals" kill -0 "$drw"
dr_rc=0; wait "$dr" || dr_rc=$?
rm -f "$work/profiles/sleep"
expect_eq "disconnect (running): the job completes green after the signals (parent exit 0)" 0 "$dr_rc"
check "disconnect (running): the verdict is retained in the root-owned result file (exit=0)" \
  bash -c 'grep -q " exit=0 " "$1/$2"' _ "$PNEUMA_GATE_RESULTS_DIR" "$drid"
check "disconnect (running): the job log keeps the verdict line" \
  bash -c 'grep -q "^PNEUMA_GATE_RESULT .* exit=0 " "$1/jobs/$2/log"' _ "$PNEUMA_GATE_BASE" "$drid"

# (b) exact-key reattach: a live job with the SAME scope key is followed, and its verdict is the job's ROOT-OWNED result
# file, never what its log says. The attaching submission starts no second job. (The scope fields that must differ are
# covered by the key tests above: repo, head, tree, submitter, profile, base, origin-main and env.)
rm -rf "$PNEUMA_GATE_DEDUP_DIR" "$PNEUMA_GATE_BASE/jobs" "$PNEUMA_GATE_BASE/queue"
mkdir -p "$PNEUMA_GATE_DEDUP_DIR" "$PNEUMA_GATE_BASE/jobs/job-rb" "$PNEUMA_GATE_RESULTS_DIR"
sleep 60 & rb_pid=$!
rb_start="$(bash -c 'source "$1"; proc_start "$2"' _ "$RUNNER" "$rb_pid")"
rb_key="$(jk fakerepo "$head" "$tree" test-lane-rb fake "$base" "" "")"   # exactly the key the submission below computes
printf 'key=fakerepo/main\nhead=%s\npid=%s\npstart=%s\nsubmitter=test-lane-rb\nunit=pneuma-gate-job-rb.service\nnonce=nonce-rb\njobkey=%s\nsuperseded=\n' \
  "$head" "$rb_pid" "$rb_start" "$rb_key" > "$PNEUMA_GATE_DEDUP_DIR/job-rb"
printf 'the job is running\n' > "$PNEUMA_GATE_BASE/jobs/job-rb/log"
printf 'PNEUMA_GATE_RESULT repo=fakerepo head=%s exit=1 elapsed=1s host=h\n' "$head" > "$PNEUMA_GATE_RESULTS_DIR/job-rb"
"$RUNNER" run --submitter test-lane-rb --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" \
  > "$work/rb.out" 2>&1 &
rbr=$!
for _ in $(seq 1 20); do grep -q 'attached to live job' "$work/rb.out" 2>/dev/null && break; sleep 1; done
printf 'PNEUMA_GATE_RESULT repo=fakerepo head=%s exit=0 elapsed=1s host=h\n' "$head" >> "$PNEUMA_GATE_BASE/jobs/job-rb/log"   # a forged green line in the LOG
kill "$rb_pid" 2>/dev/null; wait "$rb_pid" 2>/dev/null || true
rb_rc=0; wait "$rbr" || rb_rc=$?
check "reattach (b): the exact-key submission attaches to the live job (same id)" grep -q "attached to live job job-rb" "$work/rb.out"
check "reattach (b): the attached client sees the job's own log" grep -q "the job is running" "$work/rb.out"
expect_eq "reattach (b): the verdict is the job's root-owned result (1), not the forged green line in its log" 1 "$rb_rc"
expect_eq "reattach (b): no second job was started for the same scope" 1 "$(ls "$PNEUMA_GATE_BASE/jobs" | wc -l)"
rm -f "$PNEUMA_GATE_RESULTS_DIR/job-rb"

# CONCURRENCY (P0 follow-up): 24 runs record their shallow boundaries into ONE store at once. Each must succeed and
# every boundary must be recorded. The old fixed temp name made concurrent runs' mv fail ("cannot stat shallow.new").
sstore="$work/shstore.git"; git init -q --bare "$sstore"
shallow_race_ok() {
  local i rcs="$work/shrc" n
  : > "$rcs"
  for i in $(seq 1 24); do
    ( ddo record_shallow "$sstore" "$(printf '%040x' "$i")" >/dev/null 2>&1; echo $? >> "$rcs" ) &
  done
  wait
  n="$(sort -u "$sstore/shallow" 2>/dev/null | wc -l)"
  [ "$(grep -c '^0$' "$rcs")" = 24 ] && [ "$n" = 24 ]
}
check "shallow race: 24 concurrent runs of one store all succeed and every boundary is recorded" shallow_race_ok
check "shallow race: no stale temp file is left in the store" bash -c 'test -z "$(ls "$1"/shallow.* 2>/dev/null)"' _ "$sstore"

# CONCURRENCY: 8 runs fetch keep refs of the same repo, at different heads, into ONE store at once; every fetch succeeds.
for k in 1 2 3 4 5 6 7 8; do
  case $((k % 4)) in 0) cur="$C1";; 1) cur="$C2";; 2) cur="$C3";; 3) cur="$CX";; esac
  dgit update-ref refs/pneuma-gate/repo/repoR "$cur"
  dgit bundle create "$work/race$k.bundle" refs/pneuma-gate/repo/repoR >/dev/null 2>&1
done
dgit update-ref -d refs/pneuma-gate/repo/repoR
rstore="$work/rstore.git"; git init -q --bare "$rstore"
fetch_race_ok() {
  local k rcs="$work/fetchrc"
  : > "$rcs"
  for k in 1 2 3 4 5 6 7 8; do
    # production takes the store's promote lock around the fetch (cmd_promote): the test does the same
    ( exec 7>"$rstore/.promote.lock"; flock 7; ddo fetch_keep_refs "$rstore" "$work/race$k.bundle" repoR "" >/dev/null 2>&1; echo $? >> "$rcs" ) &
  done
  wait
  [ "$(grep -c '^0$' "$rcs")" = 8 ]
}
check "keep fetch race: 8 concurrent keep-ref fetches of one repo all succeed (no silent rejection)" fetch_race_ok


# ════ VM17 third pass (h): a result that cannot be read is a refusal ════
# (h) a missing, malformed or unreadable ROOT-OWNED result file is never a green verdict: job_exit returns 75, and an
# attach that depends on such a file is refused the same way
hr="$PNEUMA_GATE_RESULTS_DIR"; mkdir -p "$hr"
printf 'PNEUMA_GATE_RESULT repo=x exit=0 elapsed=1s host=h\n' > "$hr/h-ok"
printf 'garbage with no verdict\n' > "$hr/h-garbage"
printf 'PNEUMA_GATE_RESULT repo=x exit=abc elapsed=1s host=h\n' > "$hr/h-badexit"
printf 'PNEUMA_GATE_RESULT repo=x exit= elapsed=1s host=h\n' > "$hr/h-emptyexit"
printf 'PNEUMA_GATE_RESULT repo=x exit=-1 elapsed=1s host=h\n' > "$hr/h-negative"
: > "$hr/h-empty"
printf 'PNEUMA_GATE_RESULT repo=x exit=0 elapsed=1s host=h\n' > "$work/h-target"; ln -sfn "$work/h-target" "$hr/h-link"
hx() { bash -c 'source "$1"; job_exit "$2"' _ "$RUNNER" "$1"; }
expect_eq "result (h): a well-formed root-owned result is read (exit 0)" 0 "$(hx h-ok)"
expect_eq "result (h): a MISSING result file is 75, never green" 75 "$(hx h-missing)"
expect_eq "result (h): a result file with no verdict line is 75" 75 "$(hx h-garbage)"
expect_eq "result (h): an empty result file is 75" 75 "$(hx h-empty)"
expect_eq "result (h): a non-numeric exit is 75" 75 "$(hx h-badexit)"
expect_eq "result (h): an empty exit is 75" 75 "$(hx h-emptyexit)"
expect_eq "result (h): a negative exit is 75" 75 "$(hx h-negative)"
expect_eq "result (h): a symlinked result (its target says exit=0) is 75" 75 "$(hx h-link)"
# the attached submission inherits the refusal: its job's result is malformed, so it exits 75 and says so
sleep 60 & rh_pid=$!
rh_start="$(bash -c 'source "$1"; proc_start "$2"' _ "$RUNNER" "$rh_pid")"
rh_key="$(jk fakerepo "$head" "$tree" test-lane-rh fake "$base" "" "")"
rm -rf "$PNEUMA_GATE_DEDUP_DIR" "$PNEUMA_GATE_BASE/jobs"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR" "$PNEUMA_GATE_BASE/jobs/job-rh"
printf 'key=fakerepo/main\nhead=%s\npid=%s\npstart=%s\nsubmitter=test-lane-rh\nunit=pneuma-gate-job-rh.service\nnonce=nonce-rh\njobkey=%s\nsuperseded=\n' \
  "$head" "$rh_pid" "$rh_start" "$rh_key" > "$PNEUMA_GATE_DEDUP_DIR/job-rh"
printf 'running\n' > "$PNEUMA_GATE_BASE/jobs/job-rh/log"
printf 'PNEUMA_GATE_RESULT repo=fakerepo head=%s exit=zz elapsed=1s host=h\n' "$head" > "$hr/job-rh"
"$RUNNER" run --submitter test-lane-rh --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" > "$work/rh.out" 2>&1 &
rhr=$!
for _ in $(seq 1 20); do grep -q 'attached to live job' "$work/rh.out" 2>/dev/null && break; sleep 1; done
kill "$rh_pid" 2>/dev/null; wait "$rh_pid" 2>/dev/null || true
rh_rc=0; wait "$rhr" || rh_rc=$?
expect_eq "result (h): an attach onto a job whose result is malformed exits 75" 75 "$rh_rc"
rm -f "$hr/job-rh"

exit "$fail"
