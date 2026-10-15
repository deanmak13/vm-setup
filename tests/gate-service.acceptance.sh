#!/usr/bin/env bash
# gate-service.acceptance.sh — acceptance of the per-run gate SERVICE on REAL systemd, as root,
# running every gate as the real DynamicUser (no RUN_AS shortcut). Not part of tests/coverage.sh
# (kcov containers have no systemd). Run it on a machine with systemd as PID 1 that is NOT a
# production host: a VM, or a privileged container with systemd (it installs the gate with
# ci-builder-gate.sh --local-host, which is the fresh-host install it also proves). Needs
# postgresql-16 (binaries only; no default cluster), python3-venv, git, iproute2 and network
# access for pip.
#
#   bash tests/gate-service.acceptance.sh [--no-mutants]
#
# Properties proven (each "mutant" line re-runs the property against a deliberately broken
# runner and must go RED, which proves the test can fail):
#   fresh-host  the installer builds the layout and a first gate runs end to end
#   isolation   run B cannot read, write or signal run A (distinct DynamicUsers)
#   cgroup      the env build, a daemonised helper and the postmaster are in the unit's cgroup
#   setsid      a setsid child dies with the unit, after a clean exit and after kill -9
#   kill-9      kill -9 of the unit leaves no process, run directory or private tmp
#   fds         the unit inherits no fd of its caller
#   slow-start  a slow-starting run keeps its reservation: capacity is not over-admitted
#   live-pg     a skipped live module is RED; a ran live module is green; the PG is loopback + capped
#   cache       a run cannot write the shared env cache; warm-env publishes it root-owned read-only
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUTANTS=1; [ "${1:-}" = --no-mutants ] && MUTANTS=0
fail=0
DESC=""
check() { if "$@" >/dev/null 2>&1; then echo "ok   $DESC"; else echo "FAIL $DESC"; fail=1; fi; }
# settled: systemd removes a unit's directories moments after the unit stops; allow it a few seconds
settled() { local i; for ((i = 0; i < 40; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.25; done; return 1; }
not() { ! "$@"; }
# ACC_ONLY=iso,kill runs only those sections (iteration aid); empty runs everything.
sect() { [ -z "${ACC_ONLY:-}" ] || [[ ",$ACC_ONLY," == *",$1,"* ]]; }

[ "$(id -u)" = 0 ] || { echo "FAIL needs root"; exit 1; }
[ "$(cat /proc/1/comm)" = systemd ] || { echo "FAIL systemd is not PID 1 here"; exit 1; }
[ -x /usr/lib/postgresql/16/bin/initdb ] || { echo "FAIL postgresql-16 binaries are required"; exit 1; }

ACC=/var/tmp/gate-acc; LOGS="$ACC/logs"; REPO="$ACC/repo"; PROF=/usr/local/lib/pneuma-gate/profiles
RUNNER=/usr/local/bin/pneuma-gate-runner
rm -rf "$ACC"; mkdir -p "$LOGS" "$REPO"
# the disk the units' private tmp lives on must be a block device (the installer requires it); a container's
# overlay root is not one, so the host disk is named explicitly, exactly as an operator would
IO_DISK="${PNEUMA_GATE_IO_DEVICE:-$(findmnt -no SOURCE -T /var/tmp | grep '^/dev/' || lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1; exit}')}"
export PNEUMA_GATE_IO_DEVICE="$IO_DISK"

# ── 1. fresh host: the installer, from nothing ───────────────────────────────
# (the packages' default cluster handling lives in ci-builder-bootstrap.sh step 1b: reproduced here)
# the bootstrap's own cron/at restriction lines, executed as written
grep -E "^printf 'root.n' > /etc/(cron|at)\.allow" "$REPO_DIR/ci-builder-bootstrap.sh" > "$ACC/cronat.sh"
[ "$(wc -l < "$ACC/cronat.sh")" = 2 ] && bash "$ACC/cronat.sh"
if pg_lsclusters 2>/dev/null | awk 'NR>1{f=1} END{exit !f}'; then pg_dropcluster --stop 16 main 2>/dev/null || true; fi
systemctl disable --now postgresql >/dev/null 2>&1 || true
DESC="fresh-host: no gate state exists before the install"
check not test -e /var/lib/pneuma-gate
bash "$REPO_DIR/ci-builder-gate.sh" --local-host --acceptance >"$LOGS/install.log" 2>&1
DESC="fresh-host: the installer succeeds"; check grep -q '^limits:' "$LOGS/install.log"
DESC="fresh-host: envs/ and wheels/ are root-owned (units get them read-only)"
check bash -c '[ "$(stat -c %U /var/lib/pneuma-gate/envs)" = root ] && [ "$(stat -c %U /var/lib/pneuma-gate/wheels)" = root ]'
DESC="fresh-host: only the object store belongs to the static pneuma-gate user"
check bash -c '[ "$(stat -c %U /var/lib/pneuma-gate/repos)" = pneuma-gate ]'
DESC="fresh-host: the state directory is root-only (0700)"
check bash -c '[ "$(stat -c %a /var/lib/pneuma-gate-state)" = 700 ]'
bad_io_out="$(PNEUMA_GATE_IO_DEVICE=/dev/no-such-disk bash "$REPO_DIR/ci-builder-gate.sh" --local-host --acceptance 2>&1)" && bad_io_rc=0 || bad_io_rc=$?
DESC="fresh-host: an install whose disk does not resolve for IOWriteBandwidthMax FAILS loudly (nonzero, named)"
check bash -c '[ "$1" != 0 ] && grep -q "no IOWriteBandwidthMax device resolves" <<<"$2"' _ "$bad_io_rc" "$bad_io_out"
if [ "$MUTANTS" = 1 ]; then
  mkdir -p "$ACC/mut-install" && cp -a "$REPO_DIR/." "$ACC/mut-install/" 2>/dev/null
  sed -i "s/if ! grep -q '^io-cap: \/dev\/' <<<\"\$status_out\"; then/if false; then/" "$ACC/mut-install/ci-builder-gate-host.sh"
  cmp -s "$REPO_DIR/ci-builder-gate-host.sh" "$ACC/mut-install/ci-builder-gate-host.sh" && { echo "FAIL mutant install did not change (no-op probe)"; fail=1; }
  mut_io_out="$(PNEUMA_GATE_IO_DEVICE=/dev/no-such-disk bash "$ACC/mut-install/ci-builder-gate.sh" --local-host --acceptance 2>&1)" && mut_io_rc=0 || mut_io_rc=$?
  DESC="fresh-host MUTANT (io-cap check removed): the install passes on a host with no resolvable disk -> the check goes RED"
  check bash -c '[ "$1" = 0 ]' _ "$mut_io_rc"
  rm -rf "$ACC/mut-install"
fi
bash "$REPO_DIR/ci-builder-gate.sh" --local-host --acceptance >"$LOGS/install.log" 2>&1   # the good install again (idempotent)
DESC="fresh-host: the guard cron runs every minute"
check grep -q '^\* \* \* \* \* root .*pneuma-gate-runner guard' /etc/cron.d/pneuma-gate-guard
DESC="fresh-host: no Ubuntu default cluster listens on 5432"
check not bash -c 'ss -H -ltn | grep -q ":5432 "'

# ── fixtures: a profile, a repo whose commits select the behaviour ───────────
cat > "$PROF/accept.sh" <<'PROFILE'
profile_cores() { echo 1; }
profile_mem_mb() { echo 1024; }
profile_env_key() { echo acceptkey; }
profile_env_build() {
  mkdir -p "$1"
  echo "ACC env_cgroup=$(cut -d: -f3 /proc/self/cgroup)"
  setsid nohup sleep 900 >/dev/null 2>&1 </dev/null & echo $! > "$1/helper.pid"
  python3 -c 'b = bytearray(160 * 1024 * 1024); b[::4096] = b"x" * len(b[::4096])'
}
profile_gate() {
  local env="$1" mode; mode="$(cat mode)"
  echo "ACC mode=$mode uid=$(id -u) user=$(id -un) rundir=$PNEUMA_GATE_RUN_DIR work=$PNEUMA_GATE_WORK_DIR env=$env"
  case "$mode" in
    probe)
      cg="$(cut -d: -f3 /proc/self/cgroup)"
      echo "ACC gate_cgroup=$cg"
      echo "ACC helper_in_cgroup=$(grep -cx "$(cat "$env/helper.pid" 2>/dev/null)" "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null)"
      echo "ACC mem_peak=$(cat "/sys/fs/cgroup$cg/memory.peak" 2>/dev/null)"
      echo "ACC fds=$(for f in /proc/$$/fd/*; do readlink "$f"; done | tr '\n' ' ')"
      touch "$PNEUMA_GATE_ENVS_MOUNT/x" 2>/dev/null && echo "ACC cache_write=LEAK" || echo "ACC cache_write=denied"
      touch /var/lib/pneuma-gate/repos/x 2>/dev/null && echo "ACC store_write=LEAK" || echo "ACC store_write=denied"
      cat /var/lib/pneuma-gate-state/runs/* >/dev/null 2>&1 && echo "ACC state_read=LEAK" || echo "ACC state_read=denied"
      echo "ACC io_max=$(grep -o 'wbps=[0-9]*' "/sys/fs/cgroup$cg/io.max" 2>/dev/null | head -1)"
      echo "ACC base_view=$(ls -A /var/lib/pneuma-gate 2>/dev/null | wc -l):$(ls -A /var/lib/pneuma-gate-state 2>/dev/null | wc -l)"
      timeout 20 systemd-run --quiet --wait --collect -- /bin/true >/dev/null 2>&1 && echo "ACC sysd_run=LEAK" || echo "ACC sysd_run=denied"
      crontab -l >/dev/null 2>&1; echo "x" | crontab - 2>/dev/null && echo "ACC crontab=LEAK" || echo "ACC crontab=denied"
      ;;
    hold) echo "SECRET-$$" > "$PNEUMA_GATE_RUN_DIR/secret"; echo "SECRET-$$" > "$PNEUMA_GATE_WORK_DIR/secret"
          sleep 40;;
    attack)
      t="$(cat target)"
      for f in "/run/pneuma-gate/$t/secret" "/run/private/pneuma-gate/$t/secret"; do
        cat "$f" >/dev/null 2>&1 && echo "ACC read_other=LEAK($f)"
      done
      echo "ACC read_other_done"
      echo x > "/run/pneuma-gate/$t/pwn" 2>/dev/null && echo "ACC write_other=LEAK" || echo "ACC write_other=denied"
      echo "ACC foreign_procs=$(ls -dn /proc/[0-9]* | awk -v me="$(id -u)" '$3 != me' | wc -l)"
      # a shared-uid mutant sees and reads everything under the other run's directories
      ls /run/pneuma-gate/ 2>/dev/null | sed 's/^/ACC sees_run=/'
      ;;
    net)
      # target = "<host-address> <wg-address>"; each probe is a TCP connect with a 3s timeout
      set -- $(cat target)
      probe() { timeout 5 python3 -c '
import socket, sys
s = socket.socket(); s.settimeout(3)
try:
    s.connect((sys.argv[1], int(sys.argv[2]))); print("open")
except Exception as e:
    print("blocked")' "$1" "$2"; }
      echo "ACC net_k3s_loopback=$(probe 127.0.0.1 6443)"
      echo "ACC net_k3s_hostaddr=$(probe "$1" 6443)"
      echo "ACC net_wg0=$(probe "$2" 6443)"
      echo "ACC net_internet=$(probe 1.1.1.1 443)"
      v6="$(timeout 5 python3 -c '
import socket
s = socket.socket(socket.AF_INET6); s.settimeout(3)
try:
    s.connect(("::1", 6443)); print("open")
except Exception:
    print("blocked")')"
      echo "ACC net_v6_loopback=$v6"
      echo "ACC net_other_loopback=$(probe 127.0.0.2 6443)"
      # the run's own loopback address works for its own listener
      timeout 10 python3 -c '
import os, socket
a = os.environ["PNEUMA_GATE_LOOPBACK"]
l = socket.socket(); l.bind((a, 0)); l.listen(1)
c = socket.socket(); c.settimeout(3)
try:
    c.connect((a, l.getsockname()[1])); print("ACC net_own_loopback=open")
except Exception:
    print("ACC net_own_loopback=blocked")' 2>&1 | sed 's/^[^A]*$//' | grep ACC
      ;;
    writer)
      dd if=/dev/zero of="$PNEUMA_GATE_WORK_DIR/big" bs=1M count="$(cat target)" status=none 2>/dev/null
      echo "ACC writer_done=$(( $(stat -c %s "$PNEUMA_GATE_WORK_DIR/big") / 1048576 ))MB";;
    daemon) setsid nohup sleep 901 >/dev/null 2>&1 </dev/null & echo "ACC child=$!"; exit 0;;
    stubborn) ( trap '' TERM; exec setsid sleep 902 ) >/dev/null 2>&1 </dev/null & echo "ACC child=$!"
              echo "ACC main=$$"; sleep 120;;
    sleepy) sleep 12; exit 0;;
    green) exit 0;;
  esac
  return 0
}
PROFILE

# a git repo; a "run" = a commit with a given mode (and optional target)
G() { git -C "$REPO" -c user.name=t -c user.email=t@t "$@"; }
G init -q -b main
echo x > "$REPO/f"; G add -A; G commit -qm base
BASE_COMMIT="$(G rev-parse HEAD)"
RUN_EXTRA=()
branch_bundle() {  # <branch>: the bundle the client ships when it names a branch (repo + branch refs at the head)
  G update-ref "refs/pneuma-gate/repo/accrepo" "$HEAD_C"; G update-ref "refs/pneuma-gate/branch/$1" "$HEAD_C"
  BUNDLE="$ACC/$HEAD_C.branch.bundle"
  G bundle create "$BUNDLE" "refs/pneuma-gate/head-$HEAD_C" "refs/pneuma-gate/repo/accrepo" "refs/pneuma-gate/branch/$1" >/dev/null 2>&1
}
commit_mode() {  # <mode> [target] → sets HEAD_C TREE_C BUNDLE
  printf '%s\n' "$1" > "$REPO/mode"; printf '%s\n' "${2:-none}" > "$REPO/target"
  G add -A; G commit -qm "mode $1 $RANDOM$RANDOM" --allow-empty
  HEAD_C="$(G rev-parse HEAD)"; TREE_C="$(G rev-parse 'HEAD^{tree}')"
  G update-ref "refs/pneuma-gate/head-$HEAD_C" "$HEAD_C"
  BUNDLE="$ACC/$HEAD_C.bundle"; G bundle create "$BUNDLE" "refs/pneuma-gate/head-$HEAD_C" >/dev/null 2>&1
}
TENV=(PNEUMA_GATE_EXPECT_HOST= PNEUMA_GATE_TIMEOUT_S=150 PNEUMA_GATE_POLL_S=1 PNEUMA_GATE_LOAD_CEILING_PCT=100000000
      PNEUMA_GATE_RESERVE_CORES=0 PNEUMA_GATE_RESERVE_MEM_MB=0 PNEUMA_GATE_MIN_FREE_GIB=5 PNEUMA_GATE_NPROC=8)
start_run() {  # <name> <runner> <profile> [extra env...]: background; log in $LOGS/<name>.log, rc in .rc
  local name="$1" runner="$2" profile="$3"; shift 3
  ( env "${TENV[@]}" "$@" "$runner" run --submitter acc-lane --profile "$profile" --repo accrepo --head "$HEAD_C" --base "$HEAD_C" \
      --tree "$TREE_C" --bundle "${RUN_EXTRA[@]}" < "$BUNDLE" > "$LOGS/$name.log" 2>&1; echo $? > "$LOGS/$name.rc" ) &
  RUN_PID=$!
}
wait_for() {  # <timeout_s> <command...>
  local t="$1"; shift; local i
  for ((i = 0; i < t * 5; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; done; return 1
}
done_run() { [ -f "$LOGS/$1.rc" ]; }
unit_of() { sed -n 's/.*launching unit \(pneuma-gate-[^ ]*\) .*/\1/p' "$LOGS/$1.log" | head -1; }
acc() { sed -n "s/.*[ ]$2=//p" "$LOGS/$1.log" | head -1 | cut -d' ' -f1; }
mark() { grep '^PNEUMA_GATE_RESULT ' "$LOGS/$1.log" | tail -1; }

# a mutated copy of the runner (the unit entry re-executes itself, so the copy is self-contained)
mutant() {  # <name> <sed expression> → path of the mutant runner
  mkdir -p /usr/local/lib/pneuma-gate/mutants
  local m="/usr/local/lib/pneuma-gate/mutants/$1"
  sed "$2" "$RUNNER" > "$m"; chmod 0755 "$m"
  cmp -s "$RUNNER" "$m" && { echo "FAIL mutant $1 did not change the runner (no-op probe)"; fail=1; }
  echo "$m"
}

# ── 2. first end-to-end gate: cgroup, env build, fds, read-only inputs ───────
if sect first; then
commit_mode probe
start_run first "$RUNNER" accept
wait_for 120 done_run first
DESC="fresh-host: a first gate runs end to end as the real DynamicUser (GREEN, exit 0)"
check grep -q 'exit=0' <<<"$(mark first)"
DESC="fresh-host: the gate user is a dynamic uid, not root, not pneuma-gate"
check bash -c '[ "$1" -ge 61184 ] && [ "$1" -le 65519 ]' _ "$(acc first uid)"
DESC="cgroup: the env build ran in the same unit cgroup as the gate"
check bash -c '[ -n "$1" ] && [ "$1" = "$2" ]' _ "$(acc first env_cgroup)" "$(acc first gate_cgroup)"
DESC="cgroup: the env build's daemonised helper is in the unit's cgroup"
check bash -c '[ "$1" = 1 ]' _ "$(acc first helper_in_cgroup)"
DESC="cgroup: the env build's memory is counted in the unit (peak >= 150MB)"
check bash -c '[ "${1:-0}" -ge 157286400 ]' _ "$(acc first mem_peak)"
DESC="cache: a run cannot write the env cache, the object store or read the root state"
check bash -c '[ "$1" = denied ] && [ "$2" = denied ] && [ "$3" = denied ]' _ "$(acc first cache_write)" "$(acc first store_write)" "$(acc first state_read)"
DESC="io: the unit carries the write-bandwidth cap (io.max wbps=...), always"
check bash -c '[ -n "$1" ]' _ "$(acc first io_max)"
DESC="fs-view: the unit sees an empty gate base and root-state directory (only its own binds)"
check bash -c '[ "$1" = 0:0 ]' _ "$(acc first base_view)"
DESC="escape: a run cannot start its own system units, nor install a crontab"
check bash -c '[ "$1" = denied ] && [ "$2" = denied ]' _ "$(acc first sysd_run)" "$(acc first crontab)"
DESC="cache: a run never publishes its own env (the cache stays empty)"
check bash -c '[ -z "$(ls -A /var/lib/pneuma-gate/envs/accept 2>/dev/null)" ]'
DESC="fresh-host: the bundle is promoted into the store by the sandboxed static owner (have = head)"
check bash -c '[ "$("$1" have --repo accrepo "$2")" = "$2" ]' _ "$RUNNER" "$HEAD_C"
DESC="fresh-host: nothing of the run is left (run directory, private tmp, unit, bundle, reservation)"
check settled bash -c '[ -z "$(ls /run/pneuma-gate 2>/dev/null)" ] && [ -z "$(ls -d /var/tmp/systemd-private-*pneuma-gate-2* 2>/dev/null)" ] && [ -z "$(find /var/lib/pneuma-gate-state/runs /var/lib/pneuma-gate-state/in -mindepth 1)" ]'
pkill -f 'sleep 900' || true   # the env build's helper has outlived nothing: it died with the unit

fi
# ── 3. isolation: B cannot read/write/see A ──────────────────────────────────
if sect iso; then
isolation() {  # <runner> <tag> → leaves $LOGS/<tag>-a/b
  local runner="$1" tag="$2"
  commit_mode hold; start_run "$tag-a" "$runner" accept
  wait_for 60 grep -q 'ACC mode=hold' "$LOGS/$tag-a.log" 2>/dev/null
  wait_for 30 test -f "$LOGS/$tag-a.log"
  wait_for 30 bash -c "grep -q 'launching unit' $LOGS/$tag-a.log"
  local ida; ida="$(unit_of "$tag-a")"; ida="${ida#pneuma-gate-}"
  wait_for 60 bash -c "[ -f /run/pneuma-gate/$ida/secret ] || [ -f /run/private/pneuma-gate/$ida/secret ]"
  commit_mode attack "$ida"; start_run "$tag-b" "$runner" accept
  wait_for 90 done_run "$tag-b"
  # while A still holds: its secret is intact and nothing was written into its directory
  ISO_SECRET="$(cat /run/pneuma-gate/$ida/secret 2>/dev/null)"; ISO_PWN="$(ls /run/pneuma-gate/$ida 2>/dev/null | grep -c pwn)"
  systemctl stop "pneuma-gate-$ida.service" >/dev/null 2>&1; wait_for 90 done_run "$tag-a"
}
isolation "$RUNNER" iso
DESC="isolation: run A and run B are different dynamic users"
check bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]' _ "$(acc iso-a uid)" "$(acc iso-b uid)"
DESC="isolation: B cannot read A's files (RuntimeDirectory secret)"
check not grep -q 'ACC read_other=LEAK' "$LOGS/iso-b.log"
DESC="isolation: B cannot write into A's run directory"
check bash -c '[ "$(sed -n "s/.*ACC write_other=//p" "$1")" = denied ] && [ "$2" = 0 ]' _ "$LOGS/iso-b.log" "$ISO_PWN"
DESC="isolation: A's secret is untouched while B ran"
check bash -c '[ -n "$1" ]' _ "$ISO_SECRET"
DESC="isolation: B cannot see other runs' processes (ProtectProc=invisible)"
check bash -c '[ "$(sed -n "s/.*ACC foreign_procs=//p" "$1")" = 0 ]' _ "$LOGS/iso-b.log"
if [ "$MUTANTS" = 1 ]; then
  m="$(mutant shared-uid 's/--property=DynamicUser=yes/--property=User=nobody/')"
  isolation "$m" isomut
  DESC="isolation MUTANT (shared uid): B reads A's secret -> the property check goes RED"
  check grep -q 'ACC read_other=LEAK' "$LOGS/isomut-b.log"
fi

fi
# ── 4. setsid child dies with the unit; kill -9 cleans everything ────────────
if sect kill; then
commit_mode daemon; start_run daemon "$RUNNER" accept; wait_for 120 done_run daemon
child="$(acc daemon child)"
DESC="setsid: a setsid nohup child outliving a clean main exit is killed with the unit"
check bash -c '[ -n "$1" ] && ! kill -0 "$1"' _ "$child"
DESC="setsid: a clean exit is GREEN"; check grep -q 'exit=0' <<<"$(mark daemon)"

killnine() {  # <runner> <tag>
  local runner="$1" tag="$2"
  commit_mode stubborn; start_run "$tag" "$runner" accept
  wait_for 90 grep -q 'ACC main=' "$LOGS/$tag.log"
  local unit; unit="$(unit_of "$tag")"; local main; main="$(systemctl show -p MainPID --value "$unit.service")"
  K_CHILD="$(acc "$tag" child)"
  kill -9 "$main"
  wait_for 60 done_run "$tag"; sleep 1
}
killnine "$RUNNER" k9
DESC="kill-9: the unit is gone"; check not systemctl is-active --quiet "$(unit_of k9).service"
DESC="kill-9: a SIGTERM-ignoring setsid child is killed with it"
check bash -c '[ -n "$1" ] && ! kill -0 "$1"' _ "$K_CHILD"
DESC="kill-9: the run directory (RuntimeDirectory) is removed by systemd"
check settled bash -c '[ -z "$(ls /run/pneuma-gate 2>/dev/null)" ]'
DESC="kill-9: the private tmp (workspace, env, PG data) is removed by systemd"
check settled bash -c '[ -z "$(ls -d /var/tmp/systemd-private-*pneuma-gate-2* 2>/dev/null)" ]'
DESC="kill-9: the verdict is RED/no-verdict, never green"; check not grep -q 'exit=0' <<<"$(mark k9)"
DESC="kill-9: its reservation and staged bundle are gone"
check settled bash -c '[ -z "$(find /var/lib/pneuma-gate-state/runs /var/lib/pneuma-gate-state/in -mindepth 1)" ]'
if [ "$MUTANTS" = 1 ]; then
  m="$(mutant killmode-process 's/KillMode=control-group/KillMode=process/; s/--property=DynamicUser=yes/--property=User=nobody/')"
  killnine "$m" k9mut
  DESC="kill-9 MUTANT (KillMode=process): the child survives -> the property check goes RED"
  check bash -c '[ -n "$1" ] && kill -0 "$1"' _ "$K_CHILD"
  kill -9 "$K_CHILD" 2>/dev/null
fi

fi
# ── 5. fds: a caller's fd never reaches the unit ─────────────────────────────
if sect fds; then
commit_mode probe
fdrun() {  # <runner> <tag> [systemd-run shim]
  ( exec 7>>/var/lib/pneuma-gate/admit.lock; env "${TENV[@]}" ${3:+PNEUMA_GATE_SYSTEMD_RUN="$3"} "$1" run --submitter acc-lane --profile accept --repo accrepo \
      --head "$HEAD_C" --base "$HEAD_C" --tree "$TREE_C" --bundle < "$BUNDLE" > "$LOGS/$2.log" 2>&1 )
}
fdrun "$RUNNER" fds
DESC="fds: the unit holds no fd of its caller (no admit.lock, no bundle, no state file)"
check not bash -c 'grep -E "ACC fds=" "$1" | grep -qE "admit.lock|pneuma-gate-state"' _ "$LOGS/fds.log"
if [ "$MUTANTS" = 1 ]; then
  cat > "$ACC/direct-shim" <<'SHIM'
#!/usr/bin/env bash
# a stand-in that runs the command in the caller's own process tree (what a non-service launch does)
for a in "$@"; do case "$a" in --property=Bind*Paths=*) spec="${a##*Paths=}"; mkdir -p "$(dirname "${spec#*:}")"; ln -sfn "${spec%%:*}" "${spec#*:}";; esac; done
while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done; shift
exec "$@"
SHIM
  chmod +x "$ACC/direct-shim"
  fdrun "$RUNNER" fdsmut "$ACC/direct-shim"
  DESC="fds MUTANT (launched outside a service): the fd leaks -> the property check goes RED"
  check bash -c 'grep -E "ACC fds=" "$1" | grep -qE "admit.lock"' _ "$LOGS/fdsmut.log"
  rm -rf /run/pneuma-gate/* /run/pneuma-gate-in   # the stand-in ran the unit as root outside any service: its debris
fi

fi
# ── 6. slow start never over-admits (reservation counts while the runner is alive) ──
if sect slow; then
slowstart() {  # <runner> <tag>
  local runner="$1" tag="$2"
  cat > "$ACC/slow-shim" <<'SHIM'
#!/usr/bin/env bash
sleep 10   # a slow unit start (loaded host): the reservation is all that holds the capacity
exec systemd-run "$@"
SHIM
  chmod +x "$ACC/slow-shim"
  commit_mode sleepy; start_run "$tag-1" "$runner" accept PNEUMA_GATE_MAX_CONCURRENT=1 PNEUMA_GATE_SYSTEMD_RUN="$ACC/slow-shim"
  wait_for 60 bash -c 'grep -qs "^state=admitted" /var/lib/pneuma-gate-state/runs/*'
  sleep 5   # longer than any age-based grace would honour
  commit_mode sleepy; start_run "$tag-2" "$runner" accept PNEUMA_GATE_MAX_CONCURRENT=1
  sleep 3
  SLOW_UNITS_EARLY="$(systemctl list-units --plain --no-legend 'pneuma-gate-*.service' | wc -l)"
  SLOW_RUN2_LAUNCHED="$(grep -c 'launching unit' "$LOGS/$tag-2.log" 2>/dev/null)"
  wait_for 120 done_run "$tag-1"; wait_for 120 done_run "$tag-2"
}
slowstart "$RUNNER" slow
DESC="slow-start: while run 1's unit has not started, run 2 is NOT admitted (reservation held by the live runner)"
check bash -c '[ "$1" = 0 ]' _ "$SLOW_RUN2_LAUNCHED"
DESC="slow-start: both runs finish GREEN in turn"
check bash -c 'grep -q exit=0 "$1" && grep -q exit=0 "$2"' _ "$LOGS/slow-1.log" "$LOGS/slow-2.log"
if [ "$MUTANTS" = 1 ]; then
  m="$(mutant age-grace 's/^runner_dead() {.*/runner_dead() { local c; c="$(stat -c %Y "$STATE_DIR\/runs\/$1" 2>\/dev\/null)" || return 0; [ $(( $(date +%s) - c )) -ge 3 ]; }\nrunner_dead_unused() { :; }  # mutant/')"
  slowstart "$m" slowmut
  DESC="slow-start MUTANT (reservation by age): run 2 is over-admitted -> the property check goes RED"
  check bash -c '[ "$1" != 0 ]' _ "$SLOW_RUN2_LAUNCHED"
fi
pkill -f 'sleep 120' || true

fi
# ── 7. live Postgres: the real engine functions, real PG16, real junit ───────
if sect pg; then
cat > "$PROF/acceptpg.sh" <<'PROFILE'
source /usr/local/lib/pneuma-gate/profiles/engine.sh
profile_cores() { echo 2; }
profile_mem_mb() { echo 2048; }
profile_env_key() { echo accpgkey; }
profile_wheels_tag() { :; }
profile_env_build() { echo "ACC slot_owner_mode=$(stat -c '%u:%a' "$1") me=$(id -u)"; python3 -m venv "$1/venv" && "$1/venv/bin/pip" install -q --disable-pip-version-check pytest; }
eval "$(declare -f _engine_run_live | sed '1s/_engine_run_live/_orig_run_live/')"
_engine_run_live() {
  pid="$(head -1 "$PNEUMA_GATE_WORK_DIR/pg/data/postmaster.pid")"
  echo "ACC pg_cgroup=$(cut -d: -f3 /proc/$pid/cgroup) gate_cgroup=$(cut -d: -f3 /proc/self/cgroup) pg_uid=$(stat -c %u /proc/$pid)"
  echo "ACC pg_settings=$(/usr/lib/postgresql/16/bin/psql "$PGTEST_DSN" -Atc "select current_setting('shared_buffers')||','||current_setting('max_connections')||','||current_setting('listen_addresses')")"
  echo "ACC pg_listen=$(ss -H -ltn | awk -v p=":${PGTEST_DSN##*:}" '$4 ~ ("^127.0.0.1" ) {print $4}' | tr '\n' ' ')"
  _orig_run_live "$@"
}
PROFILE
mkdir -p "$ACC/pgrepo" && cd "$ACC/pgrepo" && git init -q -b main
mkdir -p tools/ci tests/integration .githooks
touch tools/__init__.py tools/ci/__init__.py tests/__init__.py tests/integration/__init__.py
cat > tools/ci/pgtest_env.py <<'PY'
import os
import pytest


def require_pgtest_dsn() -> str:
    dsn = os.environ.get("PGTEST_DSN")
    if not dsn:
        pytest.skip("PGTEST_DSN is not set. Run via tools/ci/with_test_postgres.sh", allow_module_level=True)
    return dsn
PY
cat > tests/integration/test_live.py <<'PY'
import subprocess

from tools.ci.pgtest_env import require_pgtest_dsn

DSN = require_pgtest_dsn()


def test_roundtrip():
    out = subprocess.run(["/usr/lib/postgresql/16/bin/psql", DSN, "-Atc", "select 1+1"],
                         capture_output=True, text=True, check=True).stdout.strip()
    assert out == "2"
PY
printf '#!/usr/bin/env bash\necho "ACC hook_pgport=${PGTEST_DSN##*:}"\n[ -f hold ] && { echo "ACC hook_main=$$"; sleep 200; }\nexit 0\n' > .githooks/pre-push
chmod +x .githooks/pre-push
PG="git -C $ACC/pgrepo -c user.name=t -c user.email=t@t"
$PG add -A && $PG commit -qm live
pg_commit() {  # <variant: ok|skip|hold>
  cd "$ACC/pgrepo"
  case "$1" in
    ok) rm -f hold; sed -i '/forced skip/d' tests/integration/test_live.py;;
    skip) rm -f hold; git checkout -q HEAD~0 -- tests/integration/test_live.py 2>/dev/null
          sed -i '/forced skip/d' tests/integration/test_live.py
          sed -i 's/^DSN = require_pgtest_dsn()/pytest.skip("PGTEST_DSN is not set (forced skip)", allow_module_level=True)\nDSN = require_pgtest_dsn()/; s/^import subprocess/import subprocess\n\nimport pytest/' tests/integration/test_live.py;;
    skiptest) rm -f hold; sed -i '/forced skip/d' tests/integration/test_live.py
          sed -i 's/^def test_roundtrip():/def test_roundtrip():\n    import pytest; pytest.skip("PGTEST_DSN is not set (forced skip)")/' tests/integration/test_live.py;;
    hold) touch hold;;
  esac
  $PG add -A; $PG commit -qm "pg $1 $RANDOM" --allow-empty
  HEAD_C="$($PG rev-parse HEAD)"; TREE_C="$($PG rev-parse 'HEAD^{tree}')"
  $PG update-ref "refs/pneuma-gate/head-$HEAD_C" "$HEAD_C"
  BUNDLE="$ACC/$HEAD_C.bundle"; $PG bundle create "$BUNDLE" "refs/pneuma-gate/head-$HEAD_C" >/dev/null 2>&1
  cd "$ACC"
}
pgrun() {  # <runner> <tag> <variant>: runs the real engine live step (accpg repo)
  pg_commit "$3"; local runner="$1" tag="$2"
  ( env "${TENV[@]}" PNEUMA_GATE_TIMEOUT_S=400 "$runner" run --submitter acc-lane --profile acceptpg --repo accpg --head "$HEAD_C" --base "$HEAD_C" \
      --tree "$TREE_C" --bundle < "$BUNDLE" > "$LOGS/$tag.log" 2>&1; echo $? > "$LOGS/$tag.rc" ) &
  RUN_PID=$!
}
# the env cache is filled by the operator command, for a trusted ref (never by a run)
pg_commit ok
( env "${TENV[@]}" "$RUNNER" run --submitter acc-lane --profile acceptpg --repo accpg --head "$HEAD_C" --base "$HEAD_C" --tree "$TREE_C" --bundle < "$BUNDLE" > "$LOGS/pg-seed.log" 2>&1 )  # seeds the store
( for i in $(seq 1 900); do
    slot="$(ls -d /var/lib/pneuma-gate/envs/acceptpg/.slot-* 2>/dev/null | head -1)"
    if [ -n "$slot" ]; then
      if setpriv --reuid=nobody --regid=nogroup --clear-groups touch "$slot/pwn" 2>/dev/null; then echo LEAK; else echo denied; fi
      break
    fi
    sleep 0.1
  done > "$LOGS/slot-probe.txt" ) &
env "${TENV[@]}" "$RUNNER" warm-env --profile acceptpg --repo accpg --ref "$HEAD_C" > "$LOGS/warm.log" 2>&1
wait
DESC="cache: another local user (nobody) cannot write into the slot while it builds"
check grep -qx denied "$LOGS/slot-probe.txt"
DESC="cache: the warm build slot was owner-only (0700) and owned by the build unit's dynamic uid, not world-writable"
check bash -c 'v="$(sed -n "s/.*ACC slot_owner_mode=//p" "$1" | head -1)"; u="${v%% *}"; me="${v##*me=}"; [ "${u%%:*}" = "$me" ] && [ "${u##*:}" = 700 ]' _ "$LOGS/warm.log"
DESC="cache: warm-env publishes the env for a trusted ref"; check grep -q 'published environment acceptpg/accpgkey' "$LOGS/warm.log"
DESC="cache: the published env is root-owned, marked ready and has no writable path"
check bash -c 'd=/var/lib/pneuma-gate/envs/acceptpg/accpgkey; [ "$(stat -c %U "$d")" = root ] && [ -e "$d/.ready" ] && [ -z "$(find "$d" ! -type l -perm /222 | head -1)" ] && [ -z "$(find "$d" ! -user root | head -1)" ]'
DESC="cache: warm-env is idempotent"
check grep -q 'already published' <(env "${TENV[@]}" "$RUNNER" warm-env --profile acceptpg --repo accpg --ref "$HEAD_C" 2>&1)

pgrun "$RUNNER" pgok ok; wait_for 300 done_run pgok
DESC="live-pg: a live module that ran is GREEN end to end (real PG16, real pytest, real junit)"
check bash -c 'grep -q "exit=0" "$1" && grep -q "none skipped for the DSN" "$1"' _ "$LOGS/pgok.log"
DESC="live-pg: the run used the read-only cache (no private build)"
check not grep -q 'not cached' "$LOGS/pgok.log"
DESC="live-pg: the postmaster is in the unit's cgroup (the unit's caps cover it)"
check bash -c 'l="$(sed -n "s/.*ACC pg_cgroup=//p" "$1" | head -1)"; [ "${l%% *}" = "$(sed -n "s/.*gate_cgroup=\([^ ]*\).*/\1/p" "$1" | head -1)" ]' _ "$LOGS/pgok.log"
DESC="live-pg: the postmaster runs as the run's own dynamic uid"
check bash -c '[ "$(sed -n "s/.*pg_uid=//p" "$1" | head -1)" = "$(sed -n "s/.*ACC mode.*//p;" "$1")" ] || [ "$(sed -n "s/.*pg_uid=//p" "$1" | head -1)" -ge 61184 ]' _ "$LOGS/pgok.log"
DESC="live-pg: caps applied (shared_buffers=128MB, max_connections=50) and loopback only"
check grep -qE 'ACC pg_settings=128MB,50,127\.[0-9]+\.[0-9]+\.[0-9]+$' "$LOGS/pgok.log"

pgrun "$RUNNER" pgskip skip; wait_for 300 done_run pgskip
DESC="live-pg: a SKIPPED live module is RED (exit=1), never green"
check bash -c 'grep -q "exit=1" "$1" && ! grep -q "exit=0" "$1"' _ "$LOGS/pgskip.log"
pgrun "$RUNNER" pgskiptest skiptest; wait_for 300 done_run pgskiptest
DESC="live-pg: a live TEST skipped for the DSN (pytest itself exits 0) is RED through the junit verdict"
check bash -c 'grep -q "exit=1" "$1" && grep -q "skipped for a missing PGTEST_DSN" "$1"' _ "$LOGS/pgskiptest.log"
if [ "$MUTANTS" = 1 ]; then
  mkdir -p /usr/local/lib/pneuma-gate/mutants/profiles && cp -a "$PROF/." /usr/local/lib/pneuma-gate/mutants/profiles/
  # the mutant profile's verdict ignores DSN skips and modules that ran nothing
  sed -i 's/^if dsn_skips:/if False:/; s/^if missing:/if False:/' /usr/local/lib/pneuma-gate/mutants/profiles/engine.sh
  sed -i 's#/usr/local/lib/pneuma-gate/profiles/engine.sh#/usr/local/lib/pneuma-gate/mutants/profiles/engine.sh#' /usr/local/lib/pneuma-gate/mutants/profiles/acceptpg.sh
  cmp -s "$PROF/engine.sh" /usr/local/lib/pneuma-gate/mutants/profiles/engine.sh && { echo "FAIL mutant verdict did not change engine.sh (no-op probe)"; fail=1; }
  pg_commit skiptest
  ( env "${TENV[@]}" PNEUMA_GATE_TIMEOUT_S=400 PNEUMA_GATE_PROFILE_DIR=/usr/local/lib/pneuma-gate/mutants/profiles "$RUNNER" run --submitter acc-lane --profile acceptpg --repo accpg --head "$HEAD_C" --base "$HEAD_C" --tree "$TREE_C" --bundle < "$BUNDLE" > "$LOGS/pgskipmut.log" 2>&1 )
  DESC="live-pg MUTANT (verdict ignores skips): the skipped live test goes GREEN -> the property check goes RED"
  check bash -c 'grep -q "exit=0" "$1"' _ "$LOGS/pgskipmut.log"
fi

# kill -9 with a live PG: the cluster dies with the unit
pgrun "$RUNNER" pgk9 hold
wait_for 200 grep -q 'ACC hook_main=' "$LOGS/pgk9.log"
pgport="$(sed -n 's/.*ACC hook_pgport=//p' "$LOGS/pgk9.log" | head -1 | cut -d/ -f1)"
unit="$(unit_of pgk9)"; main="$(systemctl show -p MainPID --value "$unit.service")"
DESC="live-pg: while the run is alive its PG listens on its own loopback address only"
check bash -c 'l="$(ss -H -ltn | awk -v p=":$1" "\$4 ~ p\"\$\" {print \$4}")"; [ -n "$l" ] && [ -z "$(grep -v "^127\." <<<"$l")" ] && ! grep -q "^127\.0\.0\.1:" <<<"$l"' _ "$pgport"
kill -9 "$main"; wait_for 60 done_run pgk9; sleep 2
DESC="kill-9: with a live per-run PostgreSQL, the postmaster is gone with the unit"
check bash -c '! ss -H -ltn | grep -q ":$1 " && ! pgrep -f "[/]pg/data" >/dev/null' _ "$pgport"
DESC="kill-9: and its data directory (private tmp) is removed"
check settled bash -c '[ -z "$(ls -d /var/tmp/systemd-private-*pneuma-gate-2* 2>/dev/null)" ]'

fi
# ── 8. housekeeping touches no unit and no run directory; nothing leaks at the end ──
if sect net; then
# ── 9. network: deny by default; the k3s API, wg0 and host services are unreachable ──
ip link add wg0 type dummy 2>/dev/null; ip addr add 10.99.0.1/24 dev wg0 2>/dev/null; ip link set wg0 up
HOSTADDR="$(ip -4 -o addr show scope global | awk '$2!="wg0"{print $4}' | sed 's#/.*##' | head -1)"
cat > "$ACC/listen.py" <<'PY'
import socket, sys, time
socks = []
for addr in sys.argv[1:]:
    fam = socket.AF_INET6 if ":" in addr else socket.AF_INET
    s = socket.socket(fam); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((addr, 6443)); s.listen(8); socks.append(s)
    except OSError:
        pass
time.sleep(600)
PY
python3 "$ACC/listen.py" 127.0.0.1 127.0.0.2 ::1 "$HOSTADDR" 10.99.0.1 & LISTENER=$!
sleep 1
commit_mode net; printf '%s 10.99.0.1\n' "$HOSTADDR" > "$REPO/target"; G add -A; G commit -qm net-target --allow-empty
HEAD_C="$(G rev-parse HEAD)"; TREE_C="$(G rev-parse 'HEAD^{tree}')"; G update-ref "refs/pneuma-gate/head-$HEAD_C" "$HEAD_C"
BUNDLE="$ACC/$HEAD_C.bundle"; G bundle create "$BUNDLE" "refs/pneuma-gate/head-$HEAD_C" >/dev/null 2>&1
netrun() { start_run "$1" "$2" accept; wait_for 120 done_run "$1"; }
netrun net "$RUNNER"
DESC="net: the k3s API on 127.0.0.1:6443 is unreachable from a gate unit"; check bash -c '[ "$1" = blocked ]' _ "$(acc net net_k3s_loopback)"
DESC="net: a host service on the host's own address is unreachable"; check bash -c '[ "$1" = blocked ]' _ "$(acc net net_k3s_hostaddr)"
DESC="net: wg0 (10.99.0.1) is unreachable"; check bash -c '[ "$1" = blocked ]' _ "$(acc net net_wg0)"
DESC="net: IPv6 loopback (::1) is unreachable (the policy denies IPv6 altogether)"; check bash -c '[ "$1" = blocked ]' _ "$(acc net net_v6_loopback)"
DESC="net: another loopback address (127.0.0.2) is unreachable: only the run's own address is allowed"; check bash -c '[ "$1" = blocked ]' _ "$(acc net net_other_loopback)"
DESC="net: public egress (package registries) still works"; check bash -c '[ "$1" = open ]' _ "$(acc net net_internet)"
DESC="net: the run's own loopback address works for its own listener"; check bash -c '[ "$1" = open ]' _ "$(acc net net_own_loopback)"
if [ "$MUTANTS" = 1 ]; then
  m="$(mutant open-net 's/--property=IPAddressDeny=any/--property=CPUWeight=100/')"
  netrun netmut "$m"
  DESC="net MUTANT (IPAddressDeny removed): the k3s API is reachable -> the property check goes RED"
  check bash -c '[ "$1" = open ]' _ "$(acc netmut net_k3s_loopback)"
fi
kill "$LISTENER" 2>/dev/null; ip link del wg0 2>/dev/null
fi

if sect disk; then
# ── 10. disk: a fast writer is stopped before the eviction line ───────────────
IODEV="$IO_DISK"
GIB=1073741824
free_bytes() { df -B1 --output=avail /var/tmp | tail -1 | tr -dc 0-9; }
diskrun() {  # <name> <runner> <abort GiB> → min free bytes seen in $DISK_MIN
  local name="$1" runner="$2" abort="$3"
  commit_mode writer; printf '4000\n' > "$REPO/target"; G add -A; G commit -qm w --allow-empty
  HEAD_C="$(G rev-parse HEAD)"; TREE_C="$(G rev-parse 'HEAD^{tree}')"; G update-ref "refs/pneuma-gate/head-$HEAD_C" "$HEAD_C"
  BUNDLE="$ACC/$HEAD_C.bundle"; G bundle create "$BUNDLE" "refs/pneuma-gate/head-$HEAD_C" >/dev/null 2>&1
  start_run "$name" "$runner" accept PNEUMA_GATE_ABORT_FREE_GIB="$abort" PNEUMA_GATE_IO_DEVICE="$IODEV" PNEUMA_GATE_IO_WRITE_MAX=200M PNEUMA_GATE_TIMEOUT_S=300
  DISK_MIN=$(free_bytes)
  while ! done_run "$name"; do local f; f=$(free_bytes); [ "$f" -lt "$DISK_MIN" ] && DISK_MIN=$f; sleep 0.2; done
}
START_FREE=$(( $(free_bytes) / GIB ))
ABORT=$(( START_FREE - 2 ))      # the stand-in "eviction margin": the guard line sits 2GiB below where we start
diskrun diskguard "$RUNNER" "$ABORT"
echo "     disk: start=${START_FREE}GiB guard line=${ABORT}GiB lowest free seen=$((DISK_MIN / 1048576))MiB (line=$((ABORT * 1024))MiB)"
DESC="disk: a fast writer is stopped by the guard (result 75, builder disk low), never green"
check bash -c 'grep -q "builder disk low" "$1" && grep -q "exit=75" "$1"' _ "$LOGS/diskguard.log"
DESC="disk: the writer did not finish its 4000MB"; check bash -c '! grep -q "writer_done=4000MB" "$1"' _ "$LOGS/diskguard.log"
# The real guard line is 35GiB and the kubelet evicts near 29GiB: 6GiB of margin. The burst after the
# line (poll <= 1s at the IOWriteBandwidthMax cap, the stop, and the writeback of already dirty pages) must
# fit in half of it.
DESC="disk: free space never fell more than 3GiB (half the guard-to-eviction margin) below the guard line"
check bash -c '[ "$1" -ge $(( ($2 - 3) * $3 )) ]' _ "$DISK_MIN" "$ABORT" "$GIB"
DESC="disk: the run's private tmp is gone once the unit is stopped"
check settled bash -c '[ -z "$(ls -d /var/tmp/systemd-private-*pneuma-gate-2* 2>/dev/null)" ]'
if [ "$MUTANTS" = 1 ]; then
  diskrun diskmut "$RUNNER" 0
  DESC="disk MUTANT (guard line unreachable): the writer runs to completion -> the property check goes RED"
  check bash -c 'grep -q "writer_done=4000MB" "$1"' _ "$LOGS/diskmut.log"
fi
fi

if sect orphan; then
# ── 11. a SIGKILLed runner: the guard (cron / janitor) stops its unit ─────────
orphan() {  # <runner-for-guard> <tag>
  local guard="$1" tag="$2"
  commit_mode hold; start_run "$tag" "$RUNNER" accept
  wait_for 90 bash -c "grep -q 'ACC mode=hold' $LOGS/$tag.log"
  local unit; unit="$(unit_of "$tag")"
  # the runner's pid comes from its own reservation marker (the mutant runner has another file name)
  kill -9 "$(sed -n 's/^pid=//p' "/var/lib/pneuma-gate-state/runs/${unit#pneuma-gate-}")"
  sleep 1
  ORPHAN_ACTIVE_BEFORE="$(systemctl is-active "$unit.service")"
  "$guard" janitor >/dev/null 2>&1
  sleep 3
  ORPHAN_ACTIVE_AFTER="$(systemctl is-active "$unit.service")"
  ORPHAN_UNIT="$unit"
}
orphan "$RUNNER" orphan
DESC="orphan: kill -9 of the runner leaves its unit running (the runner's own guard died with it)"
check bash -c '[ "$1" = active ]' _ "$ORPHAN_ACTIVE_BEFORE"
DESC="orphan: the janitor (guard) stops the unit whose runner is dead"
check bash -c '[ "$1" != active ]' _ "$ORPHAN_ACTIVE_AFTER"
DESC="orphan: its run directory and private tmp go with it"
check settled bash -c '[ -z "$(ls /run/pneuma-gate 2>/dev/null)" ] && [ -z "$(ls -d /var/tmp/systemd-private-*pneuma-gate-2* 2>/dev/null)" ]'
find /var/lib/pneuma-gate-state/runs /var/lib/pneuma-gate-state/in -mindepth 1 -delete   # the killed runner could not clean its own
if [ "$MUTANTS" = 1 ]; then
  m="$(mutant no-guard 's/if \[ "\$low" = 1 \] || ! runner_alive "\$id"; then/if [ "$low" = 1 ] || false; then/')"
  orphan "$m" orphanmut
  DESC="orphan MUTANT (guard ignores dead runners): the unit keeps running -> the property check goes RED"
  check bash -c '[ "$1" = active ]' _ "$ORPHAN_ACTIVE_AFTER"
  systemctl stop "$ORPHAN_UNIT.service" >/dev/null 2>&1
  find /var/lib/pneuma-gate-state/runs /var/lib/pneuma-gate-state/in -mindepth 1 -delete
fi
fi

if sect super; then
# ── 12. GATE-DEDUP-1 on real systemd: a newer head of the branch cancels the older gate by unit name ──
commit_mode hold; branch_bundle feat; RUN_EXTRA=(--branch feat)
start_run supA "$RUNNER" accept
wait_for 90 bash -c "grep -q 'ACC mode=hold' $LOGS/supA.log"
unitA="$(unit_of supA)"
commit_mode sleepy; branch_bundle feat
t0=$(date +%s); start_run supB "$RUNNER" accept
wait_for 120 done_run supA
secsA=$(( $(date +%s) - t0 ))
wait_for 120 done_run supB
RUN_EXTRA=()
DESC="dedup: the older gate of the same branch and submitter is cancelled (superseded, result 75), well before its 40s hold"
check bash -c 'grep -q "superseded by" "$1" && grep -q "exit=75" "$1" && [ "$2" -lt 30 ]' _ "$LOGS/supA.log" "$secsA"
DESC="dedup: the newer gate runs to a green verdict"; check grep -q 'exit=0' <<<"$(mark supB)"
DESC="dedup: the cancelled unit is gone and left nothing behind"
check settled bash -c '! systemctl is-active --quiet "$1.service" && [ -z "$(ls /run/pneuma-gate 2>/dev/null)" ] && [ -z "$(find /var/lib/pneuma-gate-state/runs /var/lib/pneuma-gate-state/in -mindepth 1)" ]' _ "$unitA"
DESC="dedup: both runs' own records are removed at the end of the run (a SIGKILLed runner's stale record is main's lazy cleanup)"
idA="$(unit_of supA)"; idB="$(unit_of supB)"
check settled bash -c '[ ! -e "/var/lib/pneuma-gate-dedup/${1#pneuma-gate-}" ] && [ ! -e "/var/lib/pneuma-gate-dedup/${2#pneuma-gate-}" ]' _ "$idA" "$idB"
DESC="entry: a submission with no submitter identity is refused (75), never run"
check bash -c '"$1" run --profile accept --repo accrepo --head "$2" --base "$2" --tree "$3" >/dev/null 2>&1; [ $? = 75 ]' _ "$RUNNER" "$HEAD_C" "$TREE_C"
fi

if sect cap; then
# ── 13. capacity cap: unknown liveness is OCCUPIED; only positive proof of death frees a slot ──
gcap() { PNEUMA_GATE_MAX_CONCURRENT=1 "$@"; }
mkdir -p /var/lib/pneuma-gate-state/runs
printf 'pid=nonsense\npstart=1\ncores=1\nmem_mb=256\nstate=admitted\n' > /var/lib/pneuma-gate-state/runs/zz-unknown
commit_mode green; start_run capA "$RUNNER" accept PNEUMA_GATE_MAX_CONCURRENT=1
sleep 8
DESC="cap: with a reservation of unknown liveness holding the only slot, a gate is NOT launched (queued)"
check bash -c '! grep -q "launching unit" "$1" && grep -q "queued" "$1"' _ "$LOGS/capA.log"
"$RUNNER" janitor >/dev/null 2>&1
DESC="cap: the janitor does not reclaim a reservation it cannot examine"
check test -e /var/lib/pneuma-gate-state/runs/zz-unknown
printf 'pid=999999\npstart=7\ncores=1\nmem_mb=256\nstate=admitted\n' > /var/lib/pneuma-gate-state/runs/zz-unknown
DESC="cap: once the owner is positively dead the slot frees and the gate runs green"
wait_for 60 done_run capA
check grep -q 'exit=0' <<<"$(mark capA)"
DESC="cap: a unit-listing failure refuses admission (queue timeout, 75), the gate is never started blind"
PATH_BAK="$PATH"; mkdir -p "$ACC/badctl"; printf '#!/bin/sh\n[ "$1" = list-units ] && exit 1\nexec /usr/bin/systemctl "$@"\n' > "$ACC/badctl/systemctl"; chmod +x "$ACC/badctl/systemctl"
commit_mode green; start_run capB "$RUNNER" accept PNEUMA_GATE_SYSTEMCTL="$ACC/badctl/systemctl" PNEUMA_GATE_QUEUE_TIMEOUT_S=4
wait_for 60 done_run capB
check bash -c 'grep -q "queue timeout" "$1" && ! grep -q "launching unit" "$1" && grep -q "exit=75" "$1"' _ "$LOGS/capB.log"
find /var/lib/pneuma-gate-state/runs /var/lib/pneuma-gate-state/in -mindepth 1 -delete
DESC="authz: through the submit path (SUDO_USER=pneuma-submit) the operator verbs are refused"
check bash -c 'for v in janitor guard warm-env unit promote; do SUDO_USER=pneuma-submit "$1" "$v" >/dev/null 2>&1; [ $? = 75 ] || exit 1; done' _ "$RUNNER"
DESC="authz: a submitter over its cap is refused before anything is staged (no bundle, no store, no route)"
mkdir -p /var/lib/pneuma-gate-dedup
sleep 120 & CAPPID=$!
for n in 1 2 3; do printf 'key=\nhead=%s\npid=%s\npstart=%s\nsubmitter=capped\nunit=pneuma-gate-c%s.service\nsuperseded=\n' "$HEAD_C" "$CAPPID" "$(sed 's/.*) //' /proc/$CAPPID/stat | awk '{print $20}')" "$n" > "/var/lib/pneuma-gate-dedup/cap-$n"; done
commit_mode green
ip_before="$(ip route show table local | grep -c 'src 127\.')"
capped_out="$(env "${TENV[@]}" "$RUNNER" run --submitter capped --profile accept --repo capfresh --head "$HEAD_C" --base "$HEAD_C" --tree "$TREE_C" --bundle < "$BUNDLE" 2>&1)" && capped_rc=0 || capped_rc=$?
check bash -c '[ "$1" = 75 ] && grep -q "already holds" <<<"$2" && [ ! -d /var/lib/pneuma-gate/repos/capfresh.git ] && [ -z "$(find /var/lib/pneuma-gate-state/in -mindepth 1)" ] && [ "$(ip route show table local | grep -c "src 127\.")" = "$3" ]' _ "$capped_rc" "$capped_out" "$ip_before"
kill "$CAPPID" 2>/dev/null; rm -f /var/lib/pneuma-gate-dedup/cap-*
fi

if sect janitor; then
commit_mode hold; start_run janitor "$RUNNER" accept
wait_for 60 bash -c "grep -q 'ACC mode=hold' $LOGS/janitor.log"
"$RUNNER" janitor >/dev/null 2>&1
DESC="janitor: running it mid-run leaves the live unit and its run directory alone"
check bash -c 'systemctl list-units --plain --no-legend "pneuma-gate-*.service" | grep -q . && ls /run/pneuma-gate | grep -q .'
systemctl stop "$(unit_of janitor).service" >/dev/null 2>&1; wait_for 60 done_run janitor
DESC="cleanup: no gate unit, run directory, reservation or staged bundle remains"
check settled bash -c '[ -z "$(systemctl list-units --plain --no-legend --state=active,activating,deactivating "pneuma-gate-*.service" "pneuma-promote-*.service" "pneuma-warm-*.service")" ] && [ -z "$(ls /run/pneuma-gate 2>/dev/null)" ] && [ -z "$(find /var/lib/pneuma-gate-state/runs /var/lib/pneuma-gate-state/in -mindepth 1)" ]'

fi
rm -rf /usr/local/lib/pneuma-gate/mutants "$PROF/accept.sh" "$PROF/acceptpg.sh"
exit "$fail"
