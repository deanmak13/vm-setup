#!/usr/bin/env bash
# tests/dev-box-disk-hygiene.sh - behaviour tests for dev-box-disk-hygiene.sh.
#
# docker, df, systemctl, logger, pgrep and loginctl are PATH-shimmed by one
# recorder script that logs every call to $FAKE_LOG. Fixtures (containers,
# volumes, free space, process hits) come from files and env vars the tests
# write. DBDH_ROOT and HOME sandbox the marker, install targets, pytest base and
# gateway release directories, so nothing outside a temp dir is touched.
# Assertions are branch-free: a failed check sets fail=1 and the run exits 1.

set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO/dev-box-disk-hygiene.sh"
T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

fail=0
FAKE_LOG="$T/calls.log"
FAKE_PS="$T/containers.txt"
FAKE_VOLS="$T/volumes.txt"
OUT="$T/out.txt"
export FAKE_LOG FAKE_PS FAKE_VOLS
export PATH="$T/bin:$PATH"
export DBDH_ROOT="$T/root"
export HOME="$T/home"
MARKER="$T/root/run/dev-box-disk-low"
PYTEST_BASE="$T/root/tmp/pytest-of-$(id -un)"
RELDIR="$HOME/.local/share/coding-gateway/releases"
UNIT="$HOME/.config/systemd/user/coding-gateway.service"

mkdir -p "$T/bin" "$T/root/run" "$HOME"

# Shared fake: dispatches on the name it was invoked as.
cat > "$T/bin/fake-cmd" <<'SHIM'
#!/usr/bin/env bash
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$FAKE_LOG"
case "$name" in
  docker)
    case "$1" in
      info) [[ -z "${FAKE_DOCKER_DOWN:-}" ]]; exit ;;
      system)
        echo 'VOLUME NAME LINKS SIZE'
        while read -r n l c s; do printf '%s %s %s\n' "$n" "$l" "$s"; done < "$FAKE_VOLS"
        echo; exit 0 ;;
      ps)
        states=' '
        for a in "$@"; do [[ $a == status=* ]] && states+="${a#status=} "; done
        while IFS='|' read -r id nm st cr lb; do
          [[ "$states" == *" $st "* ]] && printf '%s|%s|%s|%s|%s\n' "$id" "$nm" "$st" "$cr" "$lb"
        done < "$FAKE_PS"
        exit 0 ;;
      images) printf '%s\n' i1 i2 i3; exit 0 ;;
      rm)
        rc=0
        for a in "${@:2}"; do
          [[ $a == -* ]] && continue
          if [[ -n "${FAKE_RM_FAIL:-}" ]]; then echo "Error response from daemon: remove $a: boom" >&2; rc=1; continue; fi
          st=$(awk -F'|' -v i="$a" '$1 == i { print $3 }' "$FAKE_PS")
          if [[ -z "$st" ]]; then echo "Error response from daemon: No such container: $a" >&2; rc=1
          else echo "$a"; fi
        done
        exit $rc ;;
      volume)
        case "$2" in
          ls)
            dangling=0; [[ "$*" == *dangling=true* ]] && dangling=1
            while read -r n l c s; do
              (( dangling && l != 0 )) && continue
              echo "$n"
            done < "$FAKE_VOLS"
            exit 0 ;;
          inspect)
            while read -r n l c s; do
              [[ " $* " == *" $n "* ]] && printf '%s|%s\n' "$n" "$c"
            done < "$FAKE_VOLS"
            exit 0 ;;
          rm)
            rc=0
            for a in "${@:3}"; do
              [[ $a == -* ]] && continue
              l=$(awk -v n="$a" '$1 == n { print $2 }' "$FAKE_VOLS")
              if [[ -z "$l" ]]; then echo "Error response from daemon: no such volume: $a" >&2; rc=1
              elif [[ "$l" != 0 ]]; then echo "Error response from daemon: remove $a: volume is in use" >&2; rc=1
              else echo "$a"; fi
            done
            exit $rc ;;
        esac ;;
      image)
        if [[ "$2" == prune ]]; then
          [[ -z "${FAKE_PRUNE_FAIL:-}" ]] || { echo "Error: boom" >&2; exit 1; }
          echo "Total reclaimed space: 1.5GB"
        fi
        exit 0 ;;
    esac ;;
  df)
    [[ -z "${FAKE_DF_BAD:-}" ]] || exit 0
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
    printf '/dev/sda1 %s %s %s 50%% /\n' $((FAKE_TOTAL_GB * 1048576)) \
      $(( (FAKE_TOTAL_GB - FAKE_FREE_GB) * 1048576 )) $((FAKE_FREE_GB * 1048576))
    exit 0 ;;
  pgrep)
    [[ -n "${FAKE_PGREP_HIT:-}" && "$*" == *"$FAKE_PGREP_HIT"* ]] && { echo 4242; exit 0; }
    exit 1 ;;
  loginctl) echo "${FAKE_LINGER:-yes}"; exit 0 ;;
  find)
    # FAKE_FOREIGN makes the foreign-owner probe report an entry owned by another uid.
    if [[ -n "${FAKE_FOREIGN:-}" && "$*" == *"! -uid"* ]]; then echo "$1/foreign-owned"; exit 0; fi
    exec /usr/bin/find "$@" ;;
  stat)
    # FAKE_STAT_UID makes every stat report that owner, so ownership checks fail.
    if [[ -n "${FAKE_STAT_UID:-}" ]]; then
      if [[ "$*" == *%a* ]]; then echo "$FAKE_STAT_UID 755"; else echo "$FAKE_STAT_UID"; fi
      exit 0
    fi
    exec /usr/bin/stat "$@" ;;
esac
exit 0
SHIM
chmod +x "$T/bin/fake-cmd"
for n in docker df systemctl logger pgrep loginctl stat find; do ln -s "$T/bin/fake-cmd" "$T/bin/$n"; done

# Fixture helpers.
hex()  { printf '%064x' "$1"; }                  # 64-hex, like an anonymous volume id
rhex() { printf '%040x' "$1"; }                  # 40-hex, like a gateway release id
ago()  { date -u -d "$1 ago" "+$2"; }
docker_stamp() { ago "$1 $2" '%Y-%m-%d %H:%M:%S +0000 UTC'; }
rfc_stamp()    { ago "$1 $2" '%Y-%m-%dT%H:%M:%SZ'; }
# add_container <id> <name> <state> <created> [labels]
add_container() { printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$FAKE_PS"; }
# add_volume <name> <links> <created> <size>
add_volume() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$FAKE_VOLS"; }
# set_free <pct>: 1000 GiB disk with <pct> percent free (absolute floors never trip)
set_free() { export FAKE_TOTAL_GB=1000 FAKE_FREE_GB=$(( $1 * 10 )); }

reset_fakes() {
  unset FAKE_DOCKER_DOWN FAKE_PRUNE_FAIL FAKE_RM_FAIL FAKE_DF_BAD FAKE_PGREP_HIT FAKE_LINGER FAKE_STAT_UID FAKE_FOREIGN
  set_free 50
  : > "$FAKE_LOG"; : > "$FAKE_PS"; : > "$FAKE_VOLS"
  chmod -R u+w "$HOME" "$T/root" 2>/dev/null
  rm -rf "$HOME/.local" "$HOME/.config" "$T/root/usr" "$T/root/etc" "$PYTEST_BASE" "$MARKER"
  mkdir -p "$PYTEST_BASE" "$T/root/run"
  chmod 755 "$PYTEST_BASE"
}

# add_pytest_dir <name> <age>: directory whose entries are all <age> old.
add_pytest_dir() {
  mkdir -p "$PYTEST_BASE/$1"
  chmod 755 "$PYTEST_BASE/$1"   # explicit: umask may leave dirs group-writable
  echo x > "$PYTEST_BASE/$1/f.txt"
  touch -d "$2 ago" "$PYTEST_BASE/$1/f.txt" "$PYTEST_BASE/$1"
}

# add_release <n> <age>: read-only gateway release directory.
add_release() {
  mkdir -p "$RELDIR/$(rhex "$1")/bin"
  echo x > "$RELDIR/$(rhex "$1")/bin/gateway"
  touch -d "$2 ago" "$RELDIR/$(rhex "$1")/bin/gateway" "$RELDIR/$(rhex "$1")"
  chmod -R a-w "$RELDIR/$(rhex "$1")"
}

# call <args...>: run the real script; stdout+stderr to $OUT, exit code to $rc.
call() {
  "$SCRIPT" "$@" > "$OUT" 2>&1
  rc=$?
}

# expect <what> <grep-E pattern> <want count>: count matching FAKE_LOG lines.
expect() {
  local what=$1 pat=$2 want=$3 got
  got=$(grep -cE -- "$pat" "$FAKE_LOG")
  [[ "$got" -eq "$want" ]] || { echo "FAIL: $what (got $got, want $want)" >&2; fail=1; }
}

# expect_out <what> <grep-E pattern> <want count>: count matching output lines.
expect_out() {
  local what=$1 pat=$2 want=$3 got
  got=$(grep -cE -- "$pat" "$OUT")
  [[ "$got" -eq "$want" ]] || { echo "FAIL: $what (got $got, want $want)" >&2; fail=1; }
}

# --- healthy disk, nothing to select: every selection is a no-op -----------
reset_fakes
call --run
[[ "$rc" -eq 0 ]] || { echo "FAIL: --run exit $rc" >&2; fail=1; }
expect "empty selections remove no container" '^docker rm ' 0
expect "empty selections remove no volume" '^docker volume rm ' 0
expect "image prune is dangling-only" '^docker image prune -f$' 1
expect "no prune ever uses -a or --all" 'prune.* (-a|--all)' 0
expect "healthy disk raises no warning" 'daemon.warning' 0
[[ ! -e "$MARKER" ]] || { echo "FAIL: marker written at 50% free" >&2; fail=1; }

# --- containers: explicit selection ---------------------------------------
reset_fakes
add_container "$(hex 1)" tst-pg-run1 exited "$(docker_stamp 7 hours)"            # selected
add_container "$(hex 2)" web-1 exited "$(docker_stamp 7 hours)" "com.docker.compose.project=kodus"  # compose label
add_container "$(hex 3)" kodus-api exited "$(docker_stamp 7 hours)"              # keep pattern kodus*
add_container "$(hex 4)" db_kodus_main exited "$(docker_stamp 7 hours)"          # keep pattern db_kodus_*
add_container "$(hex 5)" coding-gateway-old created "$(docker_stamp 7 hours)"    # keep pattern coding-gateway-*
add_container "$(hex 6)" rabbitmq-prod exited "$(docker_stamp 7 hours)"          # keep pattern rabbitmq-prod
add_container "$(hex 7)" pg-young exited "$(docker_stamp 1 hours)"               # younger than 6h
add_container "$(hex 8)" pg-dead dead "$(docker_stamp 9 hours)"                  # selected (dead)
call --dry-run
expect_out "dry run counts two containers" '^containers: 2 would be removed' 1
expect_out "dry run names the selected containers" '^  tst-pg-run1$' 1
expect_out "dry run names the dead container" '^  pg-dead$' 1
expect "dry run removes no container" '^docker rm ' 0
call --run
expect "one batched rm call for the selection" '^docker rm ' 1
expect "old unlabelled container is removed" "^docker rm -- .*$(hex 1)( |\$)" 1
expect "dead container is removed" "^docker rm -- .*$(hex 8)( |\$)" 1
expect "compose-labelled container kept" "$(hex 2)" 0
expect "kodus keep-pattern container kept" "$(hex 3)" 0
expect "db_kodus keep-pattern container kept" "$(hex 4)" 0
expect "coding-gateway keep-pattern container kept" "$(hex 5)" 0
expect "rabbitmq-prod keep-pattern container kept" "$(hex 6)" 0
expect "young container kept" "$(hex 7)" 0
expect "container rm never forces" '^docker rm -f' 0
expect "removed container is journaled" 'logger -t dev-box-disk-hygiene -- removed container' 2
[[ "$rc" -eq 0 ]] || { echo "FAIL: --run exit $rc with containers" >&2; fail=1; }

# --- container removal failure is journaled, the pass continues --------------
reset_fakes
add_container "$(hex 1)" tst-pg-a exited "$(docker_stamp 7 hours)"
FAKE_RM_FAIL=1; export FAKE_RM_FAIL
call --run
expect "failed container rm is journaled" 'container rm: Error' 1
expect "unremoved selection is journaled" '1 selected item\(s\) not removed' 1
unset FAKE_RM_FAIL

# --- volumes: anonymous, dangling, old enough -------------------------------
reset_fakes
add_volume "$(hex 10)" 0 "$(rfc_stamp 7 hours)" 2GB                 # selected
add_volume "$(hex 11)" 0 "$(rfc_stamp 1 hours)" 1GB                 # younger than 2h
add_volume pgdata 0 "$(rfc_stamp 7 hours)" 3GB                      # named
add_volume "$(hex 12)" 1 "$(rfc_stamp 7 hours)" 4GB                 # in use
call --dry-run
expect_out "dry run counts one volume at 2.0GB" '^volumes: 1 would be removed \(2.0GB\)' 1
expect "dry run removes no volume" '^docker volume rm ' 0
call --run
expect "old anonymous dangling volume is removed" "^docker volume rm -- $(hex 10)\$" 1
expect "young anonymous volume kept" "^docker volume rm .*$(hex 11)" 0
expect "named volume kept" '^docker volume rm .*pgdata' 0
expect "in-use anonymous volume kept" "^docker volume rm .*$(hex 12)" 0
expect "volume removal is journaled" 'logger -t dev-box-disk-hygiene -- removed volume' 1
expect "volume rm never forces" '^docker volume rm -f' 0

# --- pytest temp dirs ------------------------------------------------------
reset_fakes
add_pytest_dir pytest-0 5hours         # old, unreferenced: selected
add_pytest_dir pytest-1 5hours         # old, a process references it: kept
add_pytest_dir pytest-2 10minutes      # young: kept
ln -s pytest-2 "$PYTEST_BASE/pytest-current"
export FAKE_PGREP_HIT="$PYTEST_BASE/pytest-1"
call --dry-run
expect_out "dry run counts one pytest dir" '^pytest: 1 would be removed' 1
expect "dry run removes no pytest dir" '^docker (rm|volume rm|image prune) ' 0
[[ -d "$PYTEST_BASE/pytest-0" ]] || { echo "FAIL: dry run removed pytest-0" >&2; fail=1; }
call --run
[[ ! -e "$PYTEST_BASE/pytest-0" ]] || { echo "FAIL: old unreferenced pytest dir kept" >&2; fail=1; }
[[ -d "$PYTEST_BASE/pytest-1" ]] || { echo "FAIL: process-referenced pytest dir removed" >&2; fail=1; }
[[ -d "$PYTEST_BASE/pytest-2" ]] || { echo "FAIL: young pytest dir removed" >&2; fail=1; }
[[ -L "$PYTEST_BASE/pytest-current" ]] || { echo "FAIL: pytest-current symlink touched" >&2; fail=1; }
expect "pytest removal is journaled" 'logger -t dev-box-disk-hygiene -- removed pytest temp dir' 1
unset FAKE_PGREP_HIT

# --- gateway releases: keep active, referenced and 2 newest others ----------
reset_fakes
add_release 1 4hours                    # active (unit): kept
add_release 2 5hours                    # referenced by a process: kept
add_release 3 1hours                    # newest other: kept
add_release 4 2hours                    # second newest other: kept
add_release 5 3hours                    # third other: removed (read-only tree)
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
export FAKE_PGREP_HIT="$RELDIR/$(rhex 2)"
call --dry-run
expect_out "dry run counts one superseded release" '^releases: 1 would be removed' 1
expect_out "dry run keeps the active release" 'active=1' 1
[[ -d "$RELDIR/$(rhex 5)" ]] || { echo "FAIL: dry run removed a release" >&2; fail=1; }
call --run
[[ ! -e "$RELDIR/$(rhex 5)" ]] || { echo "FAIL: superseded read-only release kept" >&2; fail=1; }
for n in 1 2 3 4; do
  [[ -d "$RELDIR/$(rhex "$n")" ]] || { echo "FAIL: release $n removed, must be kept" >&2; fail=1; }
done
expect "release removal is journaled" 'logger -t dev-box-disk-hygiene -- removed gateway release' 1
unset FAKE_PGREP_HIT

# --- gateway release pass: silent without a directory, refuses without a unit --
reset_fakes
call --dry-run
expect_out "missing release directory is silent" '^releases:' 0
add_release 1 1hours
call --dry-run
expect_out "missing unit skips the release pass" '^releases: skipped \(.*not found' 1
[[ -d "$RELDIR/$(rhex 1)" ]] || { echo "FAIL: release removed without a unit" >&2; fail=1; }

# --- ownership and symlink discipline on removal -----------------------------
# Base owned by another uid: the whole pytest pass is skipped, nothing removed.
reset_fakes
add_pytest_dir pytest-0 5hours
FAKE_STAT_UID=0 export FAKE_STAT_UID
call --dry-run
expect_out "foreign-owned pytest base skips the pass" 'pytest: skipped .*not owned' 1
call --run
[[ -d "$PYTEST_BASE/pytest-0" ]] || { echo "FAIL: pytest dir removed under a foreign-owned base" >&2; fail=1; }
expect "foreign-owned pytest base is journaled as skipped" 'pytest pass skipped' 1
unset FAKE_STAT_UID

# Group/other-writable base: skipped as pytest itself would refuse it.
reset_fakes
add_pytest_dir pytest-0 5hours
chmod 775 "$PYTEST_BASE"
call --run
[[ -d "$PYTEST_BASE/pytest-0" ]] || { echo "FAIL: pytest dir removed under a group-writable base" >&2; fail=1; }
expect "group-writable pytest base is journaled as skipped" 'pytest pass skipped' 1

# A tree holding a group-writable directory is refused whole: nothing changes.
reset_fakes
add_release 1 4hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 5hours
add_release 3 3hours
add_release 4 6hours
chmod 775 "$RELDIR/$(rhex 4)/bin"
call --run
[[ -d "$RELDIR/$(rhex 4)/bin/" ]] || { echo "FAIL: group-writable release tree removed" >&2; fail=1; }
[[ -f "$RELDIR/$(rhex 4)/bin/gateway" ]] || { echo "FAIL: files in refused tree removed" >&2; fail=1; }
expect "group-writable tree refusal is journaled" 'refusing to remove .*group/other-writable' 1
expect "group-writable tree refusal is journaled as a failed removal" 'could not remove gateway release|refusing to remove' 2

# A tree holding an entry owned by another uid is refused whole.
reset_fakes
add_release 1 4hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 5hours
add_release 3 3hours
add_release 4 6hours
FAKE_FOREIGN=1 export FAKE_FOREIGN
call --run
[[ -f "$RELDIR/$(rhex 4)/bin/gateway" ]] || { echo "FAIL: tree with foreign-owned entry removed" >&2; fail=1; }
expect "foreign-owned entry refusal is journaled" 'owned by another uid' 1
unset FAKE_FOREIGN

# A candidate that is a symlink: the link and its target are both untouched.
reset_fakes
mkdir -p "$T/outside"; echo keep > "$T/outside/keep.txt"; touch -d '5 hours ago' "$T/outside/keep.txt" "$T/outside"
ln -s "$T/outside" "$PYTEST_BASE/pytest-9"
call --run
[[ -L "$PYTEST_BASE/pytest-9" ]] || { echo "FAIL: symlink candidate removed" >&2; fail=1; }
[[ -f "$T/outside/keep.txt" ]] || { echo "FAIL: symlink candidate target removed" >&2; fail=1; }

# A symlink inside an otherwise selected candidate: only the link goes, target stays.
reset_fakes
mkdir -p "$T/outside"; echo keep > "$T/outside/keep.txt"; touch -d '5 hours ago' "$T/outside/keep.txt" "$T/outside"
add_pytest_dir pytest-0 5hours
ln -s "$T/outside/keep.txt" "$PYTEST_BASE/pytest-0/link.txt"
touch -h -d '5 hours ago' "$PYTEST_BASE/pytest-0/link.txt"
touch -d '5 hours ago' "$PYTEST_BASE/pytest-0"
call --run
[[ ! -e "$PYTEST_BASE/pytest-0" ]] || { echo "FAIL: candidate with inner symlink kept" >&2; fail=1; }
[[ -f "$T/outside/keep.txt" ]] || { echo "FAIL: symlink target outside the candidate removed" >&2; fail=1; }

# Release base owned by another uid: release pass skipped, nothing removed.
reset_fakes
add_release 1 4hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 5hours
add_release 3 6hours
FAKE_STAT_UID=0 export FAKE_STAT_UID
call --dry-run
expect_out "foreign-owned releases base skips the pass" 'releases: skipped .*owned by' 1
call --run
[[ -d "$RELDIR/$(rhex 3)" ]] || { echo "FAIL: release removed under a foreign-owned base" >&2; fail=1; }
unset FAKE_STAT_UID

# A release that is a symlink to a tree outside: link and target untouched.
reset_fakes
mkdir -p "$T/outside-rel/bin"; echo x > "$T/outside-rel/bin/gateway"; touch -d '9 hours ago' "$T/outside-rel/bin/gateway" "$T/outside-rel"
add_release 1 4hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 3hours
add_release 3 2hours
ln -s "$T/outside-rel" "$RELDIR/$(rhex 9)"
call --run
[[ -L "$RELDIR/$(rhex 9)" ]] || { echo "FAIL: symlinked release removed" >&2; fail=1; }
[[ -f "$T/outside-rel/bin/gateway" ]] || { echo "FAIL: symlinked release target removed" >&2; fail=1; }

# --- empty selections never run a removal ----------------------------------
reset_fakes
add_container "$(hex 2)" web-1 exited "$(docker_stamp 7 hours)" "com.docker.compose.project=kodus"
add_volume "$(hex 11)" 0 "$(rfc_stamp 1 hours)" 1GB
add_pytest_dir pytest-0 10minutes
call --run
[[ "$rc" -eq 0 ]] || { echo "FAIL: all-kept --run exit $rc" >&2; fail=1; }
expect "all-kept run removes no container" '^docker rm ' 0
expect "all-kept run removes no volume" '^docker volume rm ' 0
[[ -d "$PYTEST_BASE/pytest-0" ]] || { echo "FAIL: young pytest dir removed on empty selection" >&2; fail=1; }

# --- dry run mutates nothing and reports every pass --------------------------
reset_fakes
add_container "$(hex 1)" tst-pg-a exited "$(docker_stamp 7 hours)"
add_volume "$(hex 10)" 0 "$(rfc_stamp 7 hours)" 2GB
add_pytest_dir pytest-0 5hours
add_release 1 4hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 3hours
call --dry-run
[[ "$rc" -eq 0 ]] || { echo "FAIL: --dry-run exit $rc" >&2; fail=1; }
expect "dry run calls no removal" '^docker (rm|volume rm|image prune|container prune|volume prune) ' 0
expect "dry run journals nothing" 'logger' 0
expect "dry run calls no rm" '^rm ' 0
expect_out "dry run reports containers" '^containers: 1 would be removed' 1
expect_out "dry run reports volumes" '^volumes: 1 would be removed \(2.0GB\)' 1
expect_out "dry run reports pytest" '^pytest: 1 would be removed' 1
expect_out "dry run reports releases (2 others: both kept)" "^releases: 0 would be removed" 1
expect_out "dry run reports images" '^images: 3 dangling would be pruned' 1
expect_out "dry run says nothing changed" 'dry run: nothing was changed' 1
[[ -d "$PYTEST_BASE/pytest-0" && -d "$RELDIR/$(rhex 2)" ]] || { echo "FAIL: dry run deleted files" >&2; fail=1; }

# --- percentage guard boundaries (1000 GiB disk) ---------------------------
reset_fakes
set_free 15
call --guard
expect "15% free runs no prune" ' prune ' 0
expect "15% free raises no warning" 'daemon.warning' 0
[[ ! -e "$MARKER" ]] || { echo "FAIL: marker written at 15% free" >&2; fail=1; }

reset_fakes
set_free 12
call --guard
expect "12% free warns once" 'daemon.warning' 1
expect "12% free prunes immediately" ' image prune -f' 1
expect "12% free does not write the low marker" 'dev-box disk LOW' 0
[[ ! -e "$MARKER" ]] || { echo "FAIL: marker written at 12% free" >&2; fail=1; }

reset_fakes
set_free 5
call --guard
expect "5% free warns on prune and on low space" 'daemon.warning' 2
expect "5% free prunes immediately" ' image prune -f' 1
expect "5% free alerts once on entry" 'dev-box disk LOW' 1
[[ -e "$MARKER" ]] || { echo "FAIL: marker not written at 5% free" >&2; fail=1; }
call --guard
expect "marker alert is not repeated while still low" 'dev-box disk LOW' 1
[[ -e "$MARKER" ]] || { echo "FAIL: marker dropped while still low" >&2; fail=1; }
set_free 50
call --guard
[[ ! -e "$MARKER" ]] || { echo "FAIL: marker not cleared after recovery" >&2; fail=1; }

# --- absolute floor: whichever of percentage or GiB trips first ------------
reset_fakes
FAKE_TOTAL_GB=200 FAKE_FREE_GB=35 export FAKE_TOTAL_GB FAKE_FREE_GB     # 17% free, 35 GiB
call --guard
expect "35 GiB free prunes though 17% is above the percent floor" ' image prune -f' 1
expect "35 GiB free warns once on the prune floor" 'daemon.warning' 1
expect "35 GiB free writes no low marker" 'dev-box disk LOW' 0

reset_fakes
FAKE_TOTAL_GB=200 FAKE_FREE_GB=25 export FAKE_TOTAL_GB FAKE_FREE_GB     # 12% free, 25 GiB
call --guard
expect "25 GiB free alerts on the low floor" 'dev-box disk LOW' 1
[[ -e "$MARKER" ]] || { echo "FAIL: marker not written below 30 GiB" >&2; fail=1; }

reset_fakes
FAKE_TOTAL_GB=387 FAKE_FREE_GB=45 export FAKE_TOTAL_GB FAKE_FREE_GB     # 11.6% free, 45 GiB
call --guard
expect "45 GiB of 387 prunes on the percent floor only" 'daemon.warning' 1

# --- docker daemon down: docker passes skipped, filesystem passes still run -
reset_fakes
FAKE_DOCKER_DOWN=1 export FAKE_DOCKER_DOWN
call --run
expect "docker down runs no docker removal" '^docker (rm|volume rm|image prune) ' 0
expect "docker down is journaled as skipped" 'skip: docker daemon not reachable' 1
call --dry-run
expect_out "dry run reports docker down" 'docker daemon not reachable; nothing to report' 1
unset FAKE_DOCKER_DOWN

# --- a failing image prune warns but the pass completes ----------------------
reset_fakes
FAKE_PRUNE_FAIL=1 export FAKE_PRUNE_FAIL
call --run
expect "failed image prune warns" 'images prune failed \(rc=1\)' 1
[[ "$rc" -eq 0 ]] || { echo "FAIL: --run exit $rc after failed prune" >&2; fail=1; }
unset FAKE_PRUNE_FAIL

# --- unreadable free space: no prune, warn -----------------------------------
reset_fakes
FAKE_DF_BAD=1 export FAKE_DF_BAD
call --guard
expect "unreadable free space warns" 'cannot read root free space' 1
expect "unreadable free space runs no prune" ' prune ' 0
call --run
expect "routine pass warns when free space is unreadable" 'cannot read root free space' 2
unset FAKE_DF_BAD

# --- install into a temp root (system) ----------------------------------------
reset_fakes
call --install
[[ "$rc" -eq 0 ]] || { echo "FAIL: --install exit $rc" >&2; fail=1; }
[[ -x "$T/root/usr/local/bin/dev-box-disk-hygiene" ]] || { echo "FAIL: binary not installed" >&2; fail=1; }
cmp -s "$SCRIPT" "$T/root/usr/local/bin/dev-box-disk-hygiene" || { echo "FAIL: installed copy differs" >&2; fail=1; }
UNITS="$T/root/etc/systemd/system"
[[ -f "$UNITS/dev-box-disk-hygiene.service" ]] || { echo "FAIL: routine service missing" >&2; fail=1; }
[[ -f "$UNITS/dev-box-disk-hygiene.timer" ]] || { echo "FAIL: routine timer missing" >&2; fail=1; }
[[ -f "$UNITS/dev-box-disk-hygiene-guard.service" ]] || { echo "FAIL: guard service missing" >&2; fail=1; }
[[ -f "$UNITS/dev-box-disk-hygiene-guard.timer" ]] || { echo "FAIL: guard timer missing" >&2; fail=1; }
grep -qx "ExecStart=$T/root/usr/local/bin/dev-box-disk-hygiene --run" "$UNITS/dev-box-disk-hygiene.service" || { echo "FAIL: routine ExecStart" >&2; fail=1; }
grep -qx "ExecStart=$T/root/usr/local/bin/dev-box-disk-hygiene --guard" "$UNITS/dev-box-disk-hygiene-guard.service" || { echo "FAIL: guard ExecStart" >&2; fail=1; }
grep -qx 'OnUnitActiveSec=15min' "$UNITS/dev-box-disk-hygiene.timer" || { echo "FAIL: routine interval" >&2; fail=1; }
grep -qx 'OnUnitActiveSec=1min' "$UNITS/dev-box-disk-hygiene-guard.timer" || { echo "FAIL: guard interval" >&2; fail=1; }
expect "system install reloads systemd" '^systemctl daemon-reload$' 1
expect "system install enables both timers" '^systemctl enable --now dev-box-disk-hygiene.timer dev-box-disk-hygiene-guard.timer$' 1
expect "system install runs no removal" '^docker (rm|volume rm|image prune) ' 0

# --- install as the user (no root, systemd USER timers) -----------------------
reset_fakes
call --install-user
[[ "$rc" -eq 0 ]] || { echo "FAIL: --install-user exit $rc" >&2; fail=1; }
UBIN="$HOME/.local/bin/dev-box-disk-hygiene"
[[ -x "$UBIN" ]] || { echo "FAIL: user binary not installed" >&2; fail=1; }
cmp -s "$SCRIPT" "$UBIN" || { echo "FAIL: user-installed copy differs" >&2; fail=1; }
UUNITS="$HOME/.config/systemd/user"
grep -qx "ExecStart=$UBIN --run" "$UUNITS/dev-box-disk-hygiene.service" || { echo "FAIL: user routine ExecStart" >&2; fail=1; }
grep -qx "ExecStart=$UBIN --guard" "$UUNITS/dev-box-disk-hygiene-guard.service" || { echo "FAIL: user guard ExecStart" >&2; fail=1; }
[[ -f "$UUNITS/dev-box-disk-hygiene-guard.timer" ]] || { echo "FAIL: user guard timer missing" >&2; fail=1; }
expect "user install reloads user systemd" '^systemctl --user daemon-reload$' 1
expect "user install enables both user timers" '^systemctl --user enable --now dev-box-disk-hygiene.timer dev-box-disk-hygiene-guard.timer$' 1
expect "user install never uses root systemd" '^systemctl (daemon-reload|enable)' 0
expect_out "lingering on is reported" 'lingering is on' 1
reset_fakes
FAKE_LINGER=no export FAKE_LINGER
call --install-user
expect_out "lingering off prints the one owner command" "sudo loginctl enable-linger $(id -un)" 1
[[ -x "$UBIN" ]] || { echo "FAIL: user install aborted with linger off" >&2; fail=1; }
unset FAKE_LINGER

# --- usage -------------------------------------------------------------------
call bogus
[[ "$rc" -eq 2 ]] || { echo "FAIL: unknown argument exit $rc, want 2" >&2; fail=1; }

if [[ $fail -eq 0 ]]; then
  echo "dev-box-disk-hygiene tests: all passed"
fi
exit "$fail"
