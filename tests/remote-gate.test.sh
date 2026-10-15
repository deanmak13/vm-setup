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
# the gate runs as a unit: stand-ins for systemd-run (runs the command inline) and systemctl
cat > "$work/bin/systemd-run-stub" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
exec "$@"
STUB
cat > "$work/bin/systemctl-dedup-stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in is-active) exit 1;; stop) echo "stop $2" >> "$WORK_STOPS"; exit 0;; esac
exit 0
STUB
chmod +x "$work/bin/systemd-run-stub" "$work/bin/systemctl-dedup-stub"
export WORK_STOPS="$work/stops.txt" PNEUMA_GATE_SYSTEMD_RUN="$work/bin/systemd-run-stub" PNEUMA_GATE_SYSTEMCTL="$work/bin/systemctl-dedup-stub"

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

# ── client end to end ────────────────────────────────────────────────────────
out=$("$CLIENT" --repo-dir "$src" --profile fake --head "$head" --base "$base" --log-dir "$work/logs" 2>&1) && rc=0 || rc=$?
echo "DBG:$out" >&2
expect_eq "client: green gate exits 0" 0 "$rc"
check "runner: the profile scope report opens the log" grep -q "scope: fake-scope base=" <<<"$out"
check "client: log names the exact head and tree" grep -q "$head" <<<"$out"
check "client: log kept on the dev side" test -n "$(ls "$work/logs"/*.log)"
check "client: dirty worktree file was NOT shipped (no LEAK)" not grep -q LEAK <<<"$out"
expect_eq "per-run workspaces are deleted after a run" 0 "$(find "$PNEUMA_GATE_BASE/runs" -mindepth 1 -maxdepth 1 | wc -l)"
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
  for ((i = 0; i < $4; i++)); do
    mkdir "$work/cap/runs/r$i"; echo $$ > "$work/cap/runs/r$i/pid"; echo "$5" > "$work/cap/runs/r$i/cores"; echo "$6" > "$work/cap/runs/r$i/mem_mb"
  done
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
for i in 1 2 3; do
  # distinct submitters: three identical scopes would (correctly) attach to ONE job, and this test wants three runs
  ( "$RUNNER" run --submitter "conc-$i" --profile fake --repo fakerepo --head "$head" --base "$base" --tree "$tree" > "$work/c$i.out" 2>&1; echo $? > "$work/c$i.rc" ) &
  sleep 1
done
sleep 3
live=$(find "$PNEUMA_GATE_BASE/runs" -mindepth 1 -maxdepth 1 | wc -l)
expect_eq "concurrency: exactly 2 gates run at once, the 3rd waits" 2 "$live"
wait
chmod -R u+w "$PNEUMA_GATE_BASE/envs" 2>/dev/null || true
expect_eq "concurrency: all three finished green" "0 0 0" "$(cat "$work/c1.rc" "$work/c2.rc" "$work/c3.rc" | tr '\n' ' ' | sed 's/ $//')"
check "concurrency: the 3rd logged that it queued" grep -q 'queued:' "$work/c3.out"
check "concurrency: each run used its OWN workspace" bash -c "[ \$(cat '$work'/c?.out | grep -o 'cwd=[^ ]*' | sort -u | wc -l) = 3 ]"
check "concurrency: runs were isolated HOME/TMPDIR" bash -c "[ \$(cat '$work'/c?.out | grep -o 'home=[^ ]*' | sort -u | wc -l) = 3 ]"
expect_eq "concurrency: nothing left behind" 0 "$(find "$PNEUMA_GATE_BASE/runs" "$PNEUMA_GATE_BASE/queue" -mindepth 1 | wc -l)"
rm -f "$work/profiles/sleep"

# ── janitor reaps dead runs ─────────────────────────────────────────────────
mkdir -p "$PNEUMA_GATE_BASE/runs/dead-1"; echo 999999 > "$PNEUMA_GATE_BASE/runs/dead-1/pid"
"$RUNNER" janitor >/dev/null 2>&1
check "janitor: removes a run whose owner died" not test -e "$PNEUMA_GATE_BASE/runs/dead-1"

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
ddo() { bash -c 'source "$1"; shift; "$@"' _ "$RUNNER" "$@"; }   # one runner function, alone
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
  bash -c '! bash -c "source \"$1\"; bundle_binds \"$2\" repoA other \"$3\"" _ "$RUNNER" "$work/bind.bundle" "$C2"'
mkdir -p "$work/brokenwt" && echo "gitdir: $work/nonexistent/worktrees/x" > "$work/brokenwt/.git"
check "bundle: it binds from ANY working directory, even one with a broken worktree .git (the container case)" \
  bash -c 'cd "$3" && bash -c "source \"$1\"; bundle_binds \"$2\" repoA main \"$4\""' _ "$RUNNER" "$work/bind.bundle" "$work/brokenwt" "$C2"
check "bundle: a claimed head the bundle does not carry does NOT bind" \
  bash -c '! bash -c "source \"$1\"; bundle_binds \"$2\" repoA main \"$3\"" _ "$RUNNER" "$work/bind.bundle" "$C3"'

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
rm -rf "$PNEUMA_GATE_DEDUP_DIR"; mkdir -p "$PNEUMA_GATE_DEDUP_DIR"; : > "$WORK_STOPS"
rec2 job-c "repoA/main" "$C2" "$SUB_A"
as_sub "$SUB_B" --repo repoA --head "$C2" >/dev/null 2>&1
check "cancel: another submitter cannot cancel this job" \
  grep -qx "superseded=" "$PNEUMA_GATE_DEDUP_DIR/job-c"
as_sub "$SUB_A" --repo repoA --head "$C2" >/dev/null 2>&1
check "cancel: the submitter cancels its own job (superseded=cancelled-by-submitter)" \
  grep -qx "superseded=cancelled-by-submitter" "$PNEUMA_GATE_DEDUP_DIR/job-c"
check "cancel: the job's unit is stopped by name" \
  grep -qx "stop pneuma-gate-job-c.service" "$WORK_STOPS"
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
    ( ddo fetch_keep_refs "$rstore" "$work/race$k.bundle" repoR "" >/dev/null 2>&1; echo $? >> "$rcs" ) &
  done
  wait
  [ "$(grep -c '^0$' "$rcs")" = 8 ]
}
check "keep fetch race: 8 concurrent keep-ref fetches of one repo all succeed (no silent rejection)" fetch_race_ok

exit "$fail"
