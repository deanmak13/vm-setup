#!/usr/bin/env bash
# tests/dev-box-disk-hygiene.lib.sh - shared sandbox for the disk hygiene tests.
#
# Sourced by dev-box-disk-hygiene.sh (subprocess tests) and by
# dev-box-disk-hygiene.test.sh (in-process tests, measured by kcov).
# docker, df, systemctl, logger, pgrep, loginctl, ps, find and stat are PATH-shimmed
# by one recorder that logs every call to $FAKE_LOG. Fixtures are files the tests
# write. DBDH_ROOT and HOME sandbox every path, so nothing outside a temp dir is touched.

set -uo pipefail

LIB_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$LIB_REPO/dev-box-disk-hygiene.sh
T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

fail=0
FAKE_LOG=$T/calls.log
FAKE_PS=$T/containers.txt
FAKE_INSPECT=$T/inspect.txt
FAKE_VOLS=$T/volumes.txt
OUT=$T/out.txt
export FAKE_LOG FAKE_PS FAKE_INSPECT FAKE_VOLS
export PATH="$T/bin:$PATH"
export DBDH_ROOT="$T/root"
export HOME="$T/home"
export XDG_STATE_HOME="$T/state"
export DBDH_DOCKER_TIMEOUT=2
MARKER="$T/root/run/dev-box-disk-low"
LOCK="$T/root/run/dev-box-disk-hygiene.lock"
GRACE_FILE="$T/state/dev-box-disk-hygiene/volume-grace"
PRUNE_STAMP="$T/state/dev-box-disk-hygiene/last-prune"
PYTEST_BASE="$T/root/tmp/pytest-of-$(id -un)"
RELDIR="$HOME/.local/share/coding-gateway/releases"
UNIT="$HOME/.config/systemd/user/coding-gateway.service"

mkdir -p "$T/bin" "$T/root/run" "$HOME"

cat > "$T/bin/fake-cmd" <<'SHIM'
#!/usr/bin/env bash
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$FAKE_LOG"
case "$name" in
  docker)
    [[ -z "${FAKE_DOCKER_HANG:-}" ]] || exec sleep 300
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
      inspect)
        fmt="$*"
        while IFS='|' read -r id fin cre mnt; do
          [[ " $* " == *" $id "* ]] || continue
          if [[ "$fmt" == *FinishedAt* ]]; then printf '%s|%s|%s|%s\n' "$id" "$fin" "$cre" "$mnt"
          else printf '%s\n' "$mnt"; fi
        done < "$FAKE_INSPECT"
        exit 0 ;;
      images) printf '%s\n' i1 i2 i3; exit 0 ;;
      rm)
        rc=0
        for a in "${@:2}"; do
          [[ $a == -* ]] && continue
          if [[ -n "${FAKE_RM_FAIL:-}" ]]; then echo "Error response from daemon: remove $a: boom" >&2; rc=1; continue; fi
          st=$(awk -F'|' -v i="$a" '$1 == i { print $3 }' "$FAKE_PS")
          if [[ -z "$st" ]]; then echo "Error response from daemon: No such container: $a" >&2; rc=1; continue; fi
          mnt=$(awk -F'|' -v i="$a" '$1 == i { print $4 }' "$FAKE_INSPECT")
          for v in $(grep -oE '"Name":"[0-9a-f]{64}"' <<<"$mnt" | cut -d'"' -f4); do
            sed -i "s/^$v \([0-9]*\) /$v 0 /" "$FAKE_VOLS"
          done
          sed -i "/^$a|/d" "$FAKE_PS"
          echo "$a"
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
  ps)
    [[ -z "${FAKE_PS_FAIL:-}" ]] || exit 1
    if [[ -n "${FAKE_PGREP_HIT:-}" ]]; then /usr/bin/ps "$@"; echo "4242 bash $FAKE_PGREP_HIT"; exit 0; fi
    exec /usr/bin/ps "$@" ;;
  pgrep) exit 1 ;;
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
  loginctl) echo "${FAKE_LINGER:-yes}"; exit 0 ;;
esac
exit 0
SHIM
chmod +x "$T/bin/fake-cmd"
for n in docker df systemctl logger pgrep loginctl stat find ps; do ln -s "$T/bin/fake-cmd" "$T/bin/$n"; done

# Fixture helpers.
hex()  { printf '%064x' "$1"; }                  # 64-hex, like an anonymous volume id
rhex() { printf '%040x' "$1"; }                  # 40-hex, like a gateway release id
ago()  { date -u -d "$1 ago" "+$2"; }
docker_stamp() { ago "$1 $2" '%Y-%m-%d %H:%M:%S +0000 UTC'; }
rfc_stamp()    { ago "$1 $2" '%Y-%m-%dT%H:%M:%SZ'; }
mount_of()     { printf '[{"Type":"volume","Name":"%s"}]' "$1"; }
# add_container <id> <name> <state> <created-stamp> [labels] [finished-stamp] [mounts-json]
add_container() {
  local fin=${6:-}
  if [[ -z "$fin" ]]; then
    if [[ "$3" == created ]]; then fin=0001-01-01T00:00:00Z
    else fin=$(date -u -d "${4% UTC}" '+%Y-%m-%dT%H:%M:%SZ'); fi
  fi
  printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$FAKE_PS"
  printf '%s|%s|%s|%s\n' "$1" "$fin" "$4" "${7:-[]}" >> "$FAKE_INSPECT"
}
# add_volume <name> <links> <created-rfc> <size>
add_volume() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$FAKE_VOLS"; }
# set_free <pct>: 1000 GiB disk with <pct> percent free (absolute floors never trip)
set_free() { export FAKE_TOTAL_GB=1000 FAKE_FREE_GB=$(( $1 * 10 )); }

reset_fakes() {
  unset FAKE_DOCKER_DOWN FAKE_DOCKER_HANG FAKE_PRUNE_FAIL FAKE_RM_FAIL FAKE_DF_BAD FAKE_PGREP_HIT \
        FAKE_LINGER FAKE_STAT_UID FAKE_FOREIGN FAKE_PS_FAIL
  set_free 50
  : > "$FAKE_LOG"; : > "$FAKE_PS"; : > "$FAKE_INSPECT"; : > "$FAKE_VOLS"
  chmod -R u+w "$HOME" "$T/root" "$T/state" 2>/dev/null
  rm -rf "$HOME/.local" "$HOME/.config" "$T/root/usr" "$T/root/etc" "$PYTEST_BASE" "$MARKER" \
         "$T/state" "$T/root/tmp/claude-1000"
  mkdir -p "$PYTEST_BASE" "$T/root/run" "$T/root/tmp"
  chmod 755 "$PYTEST_BASE"
}

# add_pytest_dir <name> <age>: directory whose entries are all <age> old.
add_pytest_dir() {
  mkdir -p "$PYTEST_BASE/$1"
  chmod 755 "$PYTEST_BASE/$1"
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

# call <args...>: run the real script as a child process; output to $OUT, exit code to $rc.
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

# check_not <what> <command...>: passes only when the command fails.
check_not() {
  local what=$1; shift
  "$@" && { echo "FAIL: $what" >&2; fail=1; }
  return 0
}

# check <what> <command...>: a branch-free assertion, failing loudly.
check() {
  local what=$1; shift
  "$@" || { echo "FAIL: $what" >&2; fail=1; }
}
