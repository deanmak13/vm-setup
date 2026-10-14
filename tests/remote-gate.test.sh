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

# A fake profile: the gate passes iff the checked-out f.txt says "two" and
# the file ./PLANT_RED does not exist; it reports where it ran.
cat > "$work/profiles/fake.sh" <<'PROFILE'
profile_cores() { echo "${FAKE_CORES:-2}"; }
profile_mem_mb() { echo "${FAKE_MEM_MB:-512}"; }
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
export PATH="$work/bin:$PATH" PNEUMA_GATE_RUNNER="$RUNNER" PNEUMA_GATE_HOST=fakehost
# systemd-run stand-in: records its arguments, then runs the command after `--`.
cat > "$work/bin/systemd-run-stub" <<'STUB'
#!/usr/bin/env bash
# While the command runs, its unit is listed as active with the limits it was given
# (what systemd would show), so admission counts it exactly as it would the real unit.
printf '%s\n' "$*" >> "$SCOPE_RECORD"
unit=""; cores=1; mem=0
for a in "$@"; do
  case "$a" in
    --unit=*) unit="${a#--unit=}.service";;
    --property=CPUQuota=*) q="${a#--property=CPUQuota=}"; q="${q%\%}"; cores=$(( q / 100 ));;
    --property=MemoryMax=*) m="${a#--property=MemoryMax=}"; mem="${m%M}";;
    --) break;;
  esac
done
if [ -n "$unit" ] && [ -n "${UNITS_FILE:-}" ]; then
  printf '%s %s %s\n' "$unit" "$cores" "$mem" >> "$UNITS_FILE"
  printf '%s\n' "$unit" >> "$SYSTEMCTL_ACTIVE"
  trap 'sed -i "\|^$unit |d" "$UNITS_FILE"; sed -i "\|^$unit\$|d" "$SYSTEMCTL_ACTIVE"' EXIT
fi
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
"$@"
STUB
chmod +x "$work/bin/systemd-run-stub"
export SCOPE_RECORD="$work/scope-record.txt" PNEUMA_GATE_SYSTEMD_RUN="$work/bin/systemd-run-stub"
# systemctl stand-in: is-active reads $SYSTEMCTL_ACTIVE; list-units and show read $UNITS_FILE
# ("<unit> <cores> <mem_mb>"); a stop is recorded in $SYSTEMCTL_RECORD (the stop record).
cat > "$work/bin/systemctl-stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  is-active) grep -qx "$3" "$SYSTEMCTL_ACTIVE" 2>/dev/null && exit 0; exit 3;;
  list-units) awk '{print $1}' "$UNITS_FILE" 2>/dev/null; exit 0;;
  show)
    case "$3" in
      CPUQuotaPerSecUSec) awk -v u="$5" '$1 == u { print $2 "s" }' "$UNITS_FILE";;
      MemoryMax) awk -v u="$5" '$1 == u { print $3 * 1048576 }' "$UNITS_FILE";;
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

marker_of() { grep '^PNEUMA_GATE_RESULT ' <<<"$1" | tail -1; }
field_of() { tr ' ' '\n' <<<"$1" | sed -n "s/^$2=//p" | head -1; }

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
  loopback) echo "LISTEN 0 4096 127.0.0.1:$port 0.0.0.0:*";;
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
check "client: log names the exact head and tree" grep -q "$head" <<<"$out"
check "client: log kept on the dev side" test -n "$(ls "$work/logs"/*.log)"
check "client: dirty worktree file was NOT shipped (no LEAK)" not grep -q LEAK <<<"$out"
expect_eq "per-run workspaces are deleted after a run" 0 "$(find "$PNEUMA_GATE_BASE/work" -mindepth 1 -maxdepth 1 | wc -l)"
expect_eq "queue entries are removed after a run" 0 "$(find "$PNEUMA_GATE_BASE/queue" -mindepth 1 | wc -l)"
check "env cache is built once and frozen read-only" test -e "$PNEUMA_GATE_BASE/envs/fake/fakekey1/.ready" -a "$(stat -c %a "$PNEUMA_GATE_BASE/envs/fake/fakekey1/marker")" = 444
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

out=$(PNEUMA_GATE_EXPECT_HOST=not-the-builder "$RUNNER" run --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1) && rc=0 || rc=$?
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
check "PG: the per-run postmaster is capped (shared_buffers, connections)" bash -c 'grep -q "shared_buffers=128MB" "$1" && grep -q "max_connections=50" "$1"' _ "$PG_CAPS_CALLS"
check "scope: no systemd-run means refusal, never an unscoped gate" bash -c 'PNEUMA_GATE_SYSTEMD_RUN=/nonexistent "$1" run --profile fake --repo fakerepo --head "$2" --base "$3" --tree "$4" >/dev/null 2>&1; test $? = 75' _ "$RUNNER" "$head" "$base" "$tree"

# ── runner: tree mismatch, shallow boundary, have ────────────────────────────
out=$("$RUNNER" run --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$base" 2>&1) && rc=0 || rc=$?
expect_eq "runner: tree mismatch exits 75" 75 "$rc"
check "have: reports commits the store holds" bash -c "[ \"\$('$RUNNER' have --repo fakerepo '$head' 1111111111111111111111111111111111111111)\" = '$head' ]"
check "have: rejects a hostile repo name" not "$RUNNER" have --repo '../x' "$head"
out=$("$RUNNER" run --profile 'a/b' --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1) && rc=0 || rc=$?
expect_eq "runner: hostile profile name exits 75" 75 "$rc"

shallow_src="$work/shallow-src"
git clone -q --depth 1 "file://$src" "$shallow_src" 2>/dev/null
sh_head=$(git -C "$shallow_src" rev-parse HEAD)
printf 'two\n' > /dev/null
out=$("$CLIENT" --repo-dir "$shallow_src" --profile fake --head "$sh_head" --base "$sh_head" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
expect_eq "client: a shallow dev-box clone ships and gates" 0 "$rc"
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
  ( "$RUNNER" run --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" > "$work/c$i.out" 2>&1; echo $? > "$work/c$i.rc" ) &
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
expect_eq "concurrency: nothing left behind" 0 "$(find "$PNEUMA_GATE_BASE/work" "$PNEUMA_GATE_BASE/queue" -mindepth 1 | wc -l)"
rm -f "$work/profiles/sleep"

# ── janitor: housekeeping only; systemd owns run directories (#17 acceptance) ───
export PNEUMA_GATE_RUN_ROOT="$work/run"; mkdir -p "$PNEUMA_GATE_RUN_ROOT"
old=$(( $(date +%s) - 7200 ))
# A run directory that outlives its unit is never deleted by the janitor: systemd removes them.
leftover="$PNEUMA_GATE_RUN_ROOT/leftover-1"; mkdir -p "$leftover/work"; touch -d "@$old" "$leftover"
"$RUNNER" janitor >/dev/null 2>&1
check "janitor: never deletes a run directory (systemd owns it)" test -d "$leftover"
# FRESH HOST (review): the workspace base is created by the root runner; the gate user must
# own it, or every run fails. Structural check here; the real-user install test runs on the builder.
check "fresh host: the gate user is handed its workspace base (work/)" grep -q '"$BASE_DIR"/work 2>/dev/null' "$RUNNER"
check "janitor: never sends a unit a stop (systemd owns the lifetime)" bash -c '! grep -q "^stop " "$1"' _ "$SYSTEMCTL_RECORD"

# SLOW START (acceptance): a reservation whose unit has not come up yet, with its workspace,
# survives every janitor pass. Nothing is deleted on "unit not loaded" alone.
mkdir -p "$PNEUMA_GATE_STATE_DIR/runs" "$PNEUMA_GATE_BASE/work/slow-1"
printf 'state=pending\ncores=1\nmem_mb=512\ncreated=%s\n' "$(date +%s)" > "$PNEUMA_GATE_STATE_DIR/runs/slow-1"
touch -d "@$old" "$PNEUMA_GATE_BASE/work/slow-1"
"$RUNNER" janitor >/dev/null 2>&1
check "slow start: the workspace of a reservation whose unit is not up is kept" test -d "$PNEUMA_GATE_BASE/work/slow-1"
check "slow start: its fresh reservation marker is kept" test -f "$PNEUMA_GATE_STATE_DIR/runs/slow-1"

# Forged cores/mem in a run directory never reach admission: the unit's limits do.
mkdir -p "$PNEUMA_GATE_RUN_ROOT/live-1"; printf '64\n' > "$PNEUMA_GATE_RUN_ROOT/live-1/cores"
printf 'pneuma-gate-live-1.service 1 512\n' > "$UNITS_FILE"; printf 'pneuma-gate-live-1.service\n' > "$SYSTEMCTL_ACTIVE"
live_line="$(bash -c 'source "$1"; live_runs' _ "$RUNNER" | grep '^live-1 ')"
check "forged cores/mem: admission reads the unit's configured limits (1 core, 512MB)" test "$live_line" = "live-1 1 512"
: > "$SYSTEMCTL_ACTIVE"

# Disk cap (the real cmd_run path): the workspaces past the cap refuse new runs, named.
mkdir -p "$PNEUMA_GATE_BASE/work/bulk"; head -c 3000000 /dev/zero > "$PNEUMA_GATE_BASE/work/bulk/blob"
cap_out="$(PNEUMA_GATE_RUNS_CAP_MB=1 "$RUNNER" run --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" 2>&1)" && cap_rc=0 || cap_rc=$?
check "disk cap: admission refuses past the workspace cap (exit 75, named)" bash -c '[ "$1" = 75 ] && grep -q "gate disk over cap" <<<"$2"' _ "$cap_rc" "$cap_out"
rm -rf "$PNEUMA_GATE_BASE/work/bulk"

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

exit "$fail"
