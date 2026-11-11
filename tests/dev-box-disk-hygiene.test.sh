#!/usr/bin/env bash
# tests/dev-box-disk-hygiene.test.sh - in-process unit layer for dev-box-disk-hygiene.sh.
#
# The script is sourced (its main guard keeps it from running), so every function
# executes in this shell and kcov measures it. The subprocess behaviour suite is
# tests/dev-box-disk-hygiene.sh. Shares the sandbox and shims in the lib.

REPO_TESTS=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=dev-box-disk-hygiene.lib.sh
source "$REPO_TESTS/dev-box-disk-hygiene.lib.sh"
# shellcheck source=../dev-box-disk-hygiene.sh
source "$SCRIPT"

fresh() {
  { exec 8>&-; } 2>/dev/null     # release any lock this shell took in an earlier case
  reset_fakes
  REMOVED_THIS=0; PROC_SNAP=""; PROC_SNAP_OK=0; PROC_SNAP_TAKEN=0
}

# --- pure helpers ------------------------------------------------------------
fresh
check "keep_name matches kodus glob" keep_name kodus-api
check "keep_name matches db_kodus glob" keep_name db_kodus_main
check "keep_name matches rabbitmq-prod" keep_name rabbitmq-prod
check "keep_name matches coding-gateway glob" keep_name coding-gateway-old
check_not "keep_name rejects an unrelated name" keep_name pg-young
check_not "older_than refuses an empty stamp" older_than '' 60
check_not "older_than refuses an unparseable stamp" older_than 'not a date' 60
check "older_than accepts an old stamp" older_than "$(docker_stamp 3 days)" 3600
check_not "older_than rejects a fresh stamp" older_than "$(date -u '+%Y-%m-%d %H:%M:%S +0000 UTC')" 3600
check "gb formats bytes" [ "$(gb 2000000000)" = "2.0GB" ]
check "dir_bytes reports kilobytes as bytes" [ "$(dir_bytes "$T")" -gt 0 ]

# --- root free space and the guard's marker ----------------------------------
fresh
set_free 50
check "root_free reads the df shim" [ "$(root_free)" = "50 500 1000" ]
FAKE_DF_BAD=1 export FAKE_DF_BAD
check "root_free is empty when df is unreadable" [ -z "$(root_free)" ]
check_not "check_low_space reports unreadable space as failure" check_low_space
unset FAKE_DF_BAD
set_free 5
check_low_space
check "check_low_space writes the marker below the floor" [ -e "$MARKER" ]
set_free 50
check_low_space
check "check_low_space clears the marker above the floor" [ ! -e "$MARKER" ]

# --- process snapshot and in_use fail-safe ------------------------------------
fresh
FAKE_PGREP_HIT=/some/held/path export FAKE_PGREP_HIT
check "in_use matches a referenced path" in_use /some/held/path
PROC_SNAP_TAKEN=1; PROC_SNAP_OK=1; PROC_SNAP="unrelated"
check_not "in_use ignores an unreferenced path" in_use /not/there
PROC_SNAP_TAKEN=0
unset FAKE_PGREP_HIT
fresh
FAKE_PS_FAIL=1 export FAKE_PS_FAIL
check "an unreadable process list makes everything in use" in_use /any/path
check "a failed snapshot leaves PROC_SNAP_OK at zero" [ "$PROC_SNAP_OK" -eq 0 ]
unset FAKE_PS_FAIL

# --- grace window -------------------------------------------------------------
fresh
grace_record
check "grace_record with no names writes nothing" [ ! -e "$GRACE_FILE" ]
grace_record "$(hex 30)" "$(hex 31)"
check "grace_active sees a fresh record" grace_active "$(hex 30)"
check_not "grace_active ignores unknown names" grace_active "$(hex 99)"
sed -i "s/ [0-9]*$/ 0/" "$GRACE_FILE"
check_not "grace_active ignores an expired record" grace_active "$(hex 30)"
grace_record "$(hex 32)"
check_not "grace_record trims expired records" grep -q "$(hex 30)" "$GRACE_FILE"
rm -f -- "$GRACE_FILE"
check_not "grace_active on a missing file is false" grace_active "$(hex 32)"

# --- basetemp layout ------------------------------------------------------------
fresh
BL=$T/root/tmp/claude-1000/layout
mkdir -p "$BL/test_a0" "$BL/test_a1"; ln -s test_a1 "$BL/test_acurrent"
check "a pytest basetemp layout is recognised" basetemp_layout_ok "$BL"
echo x > "$BL/notes.txt"
check_not "a foreign entry breaks the layout" basetemp_layout_ok "$BL"
rm -f -- "$BL/notes.txt"
rm -f -- "$BL/test_acurrent"
check_not "a layout without a current link is refused" basetemp_layout_ok "$BL"
ln -s test_a1 "$BL/test_bcurrent"
check_not "a current link without a numbered sibling is refused" basetemp_layout_ok "$BL"

# --- selectors ------------------------------------------------------------------
fresh
add_container "$(hex 1)" tst-pg exited "$(docker_stamp 3 days)"
add_container "$(hex 2)" web-1 exited "$(docker_stamp 3 days)" "com.docker.compose.project=kodus"
add_container "$(hex 3)" kodus-api exited "$(docker_stamp 3 days)"
add_container "$(hex 4)" pg-young exited "$(docker_stamp 1 hours)"
add_container "$(hex 5)" pg-noinspect exited "$(docker_stamp 3 days)"
sed -i "/^$(hex 5)|/d" "$FAKE_INSPECT"
out=$(select_containers)
check "select_containers selects the old unlabelled container" grep -qP "^SEL\t$(hex 1)\t" <<<"$out"
check "select_containers keeps the compose container" grep -q "^KEEP	compose	web-1" <<<"$out"
check "select_containers keeps the keep-pattern container" grep -q "^KEEP	keep-pattern	kodus-api" <<<"$out"
check "select_containers keeps the young container" grep -q "^KEEP	stopped-recently	pg-young" <<<"$out"
check "select_containers keeps a container with no inspect data" grep -q "^KEEP	unknown-age	pg-noinspect" <<<"$out"
fresh
out=$(select_containers); check "select_containers is silent with no containers" [ -z "$out" ]

fresh
add_volume "$(hex 40)" 0 "$(rfc_stamp 3 days)" 2GB
add_volume "$(hex 41)" 0 "$(rfc_stamp 1 hours)" 1GB
add_volume pgdata 0 "$(rfc_stamp 3 days)" 3GB
add_volume "$(hex 42)" 1 "$(rfc_stamp 3 days)" 4GB
grace_record "$(hex 43)"
add_volume "$(hex 43)" 0 "$(rfc_stamp 3 days)" 1GB
out=$(select_volumes)
check "select_volumes selects the old anonymous dangling volume" grep -q "^SEL	$(hex 40)	" <<<"$out"
check "select_volumes keeps the young volume" grep -q "^KEEP	young	$(hex 41)" <<<"$out"
check "select_volumes keeps the named volume" grep -q "^KEEP	named	pgdata" <<<"$out"
check "select_volumes keeps the in-use anonymous volume" grep -q "^KEEP	in-use	$(hex 42)" <<<"$out"
check "select_volumes keeps a volume in grace" grep -q "^KEEP	grace	$(hex 43)" <<<"$out"
fresh
out=$(select_volumes); check "select_volumes is silent with no volumes" [ -z "$out" ]

fresh
add_pytest_dir pytest-0 5hours
add_pytest_dir pytest-1 10minutes
add_pytest_dir pytest-2 5hours
FAKE_PGREP_HIT="$PYTEST_BASE/pytest-2" export FAKE_PGREP_HIT
out=$(select_pytest)
check "select_pytest selects the old unreferenced dir" grep -q "^SEL	$PYTEST_BASE/pytest-0" <<<"$out"
check "select_pytest keeps the young dir" grep -q "^KEEP	young-or-unreadable	$PYTEST_BASE/pytest-1" <<<"$out"
check "select_pytest keeps the referenced dir" grep -q "^KEEP	in-use	$PYTEST_BASE/pytest-2" <<<"$out"
unset FAKE_PGREP_HIT
fresh
rm -rf -- "$PYTEST_BASE"
out=$(select_pytest); check "select_pytest is NA without a base" [ "$out" = NA ]
fresh
chmod 775 "$PYTEST_BASE"
check "select_pytest refuses a group-writable base" grep -q "^ERR" <<<"$(select_pytest)"
chmod 755 "$PYTEST_BASE"

fresh
BTR=$T/root/tmp/claude-1000
mkdir -p "$BTR/proj/test_s0" "$BTR/proj/test_s1"
echo x > "$BTR/proj/test_s0/f"; ln -s test_s1 "$BTR/proj/test_scurrent"
touch -d '3 days ago' "$BTR/proj/test_s0/f" "$BTR/proj/test_s0" "$BTR/proj/test_s1" "$BTR/proj"
touch -h -d '3 days ago' "$BTR/proj/test_scurrent"
out=$(select_basetemps)
check "select_basetemps selects the old basetemp" grep -q "^SEL	$BTR/proj	" <<<"$out"
fresh
out=$(select_basetemps); check "select_basetemps is silent with no roots" [ -z "$out" ]

fresh
out=$(select_releases); check "select_releases is NA without a directory" [ "$out" = NA ]
add_release 1 4hours
check "select_releases refuses a missing unit" grep -q "^ERR" <<<"$(select_releases)"
mkdir -p "$(dirname "$UNIT")"
printf 'NoIdHere\n' > "$UNIT"
check "select_releases refuses a unit with no release id" grep -q "^ERR" <<<"$(select_releases)"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 5hours
add_release 3 3hours
add_release 4 6hours
out=$(select_releases)
check "select_releases selects the oldest other" grep -q "^SEL	$RELDIR/$(rhex 4)	" <<<"$out"
check "select_releases keeps the active release" grep -q "^KEEP	active	$RELDIR/$(rhex 1)" <<<"$out"
check "select_releases keeps the newest others" grep -q "^KEEP	newest-2	$RELDIR/$(rhex 3)" <<<"$out"

# --- removers -----------------------------------------------------------------
fresh
D1=$T/root/tmp/pytest-of-$(id -un)/pytest-9
mkdir -p "$D1/x"; chmod 755 "$D1" "$D1/x"; echo y > "$D1/x/y"
chmod 775 "$D1/x"
check_not "remove_tree refuses a group-writable directory" remove_tree "$D1"
check "remove_tree leaves a refused tree in place" [ -f "$D1/x/y" ]
chmod 755 "$D1/x"
check "remove_tree removes a clean tree" remove_tree "$D1"
check "the clean tree is gone" [ ! -e "$D1" ]

fresh
mkdir -p "$PYTEST_BASE/pytest-7"; chmod 755 "$PYTEST_BASE/pytest-7"
remove_pytest_dirs "$PYTEST_BASE/pytest-7"
check "remove_pytest_dirs removes an owned pytest dir" [ ! -e "$PYTEST_BASE/pytest-7" ]
check "remove_pytest_dirs counts the removal" [ "$REMOVED_THIS" -eq 1 ]
mkdir -p "$T/elsewhere/pytest-8"
remove_pytest_dirs "$T/elsewhere/pytest-8"
check "remove_pytest_dirs refuses a path outside the base" [ -d "$T/elsewhere/pytest-8" ]

fresh
BTX=$T/root/tmp/claude-1000/rm/test_r0
mkdir -p "$BTX"; echo x > "$BTX/f"; ln -s test_r0 "$(dirname "$BTX")/test_rcurrent"
remove_basetemps "$BTX" "$T/root/tmp/claude-1000/rm"
check "remove_basetemps refuses a dir without the layout" [ -d "$BTX" ]

fresh
add_release 5 3hours
remove_releases "$RELDIR/$(rhex 5)"
check "remove_releases removes a release" [ ! -e "$RELDIR/$(rhex 5)" ]
mkdir -p "$RELDIR/not-a-release"
remove_releases "$RELDIR/not-a-release"
check "remove_releases refuses a non-release name" [ -d "$RELDIR/not-a-release" ]

fresh
add_container "$(hex 50)" gone exited "$(docker_stamp 3 days)" "" "$(rfc_stamp 3 days)" "$(mount_of "$(hex 51)")"
add_volume "$(hex 51)" 1 "$(rfc_stamp 3 days)" 1GB
remove_containers "$(hex 50)"
check "remove_containers records the anonymous volume in the grace window" grep -q "$(hex 51) " "$GRACE_FILE"
check "remove_containers counts the removal" [ "$REMOVED_THIS" -eq 1 ]
FAKE_RM_FAIL=1 export FAKE_RM_FAIL
REMOVED_THIS=0
remove_containers "$(hex 50)" >/dev/null 2>&1
check "remove_containers does not count a failed removal" [ "$REMOVED_THIS" -eq 0 ]
unset FAKE_RM_FAIL
REMOVED_THIS=0
remove_volumes "$(hex 51)"
check "remove_volumes counts a removed volume" [ "$REMOVED_THIS" -eq 1 ]

# --- run_pass over fake selectors -----------------------------------------------
fresh
sel_mixed() { printf 'SEL\tk1\t10\tlabel1\nKEEP\twhy\tk2\nSEL\tk3\t5\tlabel3\n'; }
rem_count() { REMOVED_THIS=0; REMOVED_LIST+=("$@"); REMOVED_THIS=${#REMOVED_LIST[@]}; }
REMOVED_LIST=()
run_pass mixed sel_mixed rem_count dry > "$OUT"
check "dry run_pass reports the selection" grep -q "mixed: 2 would be removed" "$OUT"
check "dry run_pass lists small selections" grep -q "label1" "$OUT"
REMOVED_LIST=()
run_pass mixed sel_mixed rem_count run
check "run_pass hands the keys to the remover" [ "${#REMOVED_LIST[@]}" -eq 2 ]
sel_err() { printf 'ERR\tboom\n'; }
run_pass errlabel sel_err rem_count dry > "$OUT"
check "run_pass reports a skipped pass in dry mode" grep -q "errlabel: skipped (boom)" "$OUT"
run_pass errlabel sel_err rem_count run
check "run_pass warns on a skipped pass in run mode" grep -q "errlabel pass skipped" "$FAKE_LOG"
sel_na() { printf 'NA\n'; }
run_pass nalabel sel_na rem_count run
check_not "run_pass is silent for an NA pass" grep -q nalabel "$FAKE_LOG"
sel_none() { printf ''; }
run_pass nonelabel sel_none rem_count run
check "run_pass with no selection runs no remover" [ "${#REMOVED_LIST[@]}" -eq 2 ]
sel_many() { local i; for i in $(seq 1 130); do printf 'SEL\tm%s\t1\tm%s\n' "$i" "$i"; done; }
REMOVED_LIST=()
run_pass many sel_many rem_count run
check "run_pass batches 130 keys into remover calls" [ "${#REMOVED_LIST[@]}" -eq 130 ]
sel_unremoved() { printf 'SEL\tz1\t1\tz1\nSEL\tz2\t1\tz2\n'; }
rem_none() { REMOVED_THIS=0; }
run_pass unrem sel_unremoved rem_none run
check "run_pass warns about unremoved items" grep -q "unrem: 2 selected" "$FAKE_LOG"

# --- routine pass, images, dry run, guard --------------------------------------
fresh
routine_pass dry > "$OUT"
check "routine dry pass reports images" grep -q "images:" "$OUT"
fresh
FAKE_PRUNE_FAIL=1 export FAKE_PRUNE_FAIL
check_not "prune_images fails cleanly" prune_images
unset FAKE_PRUNE_FAIL
fresh
FAKE_DOCKER_DOWN=1 export FAKE_DOCKER_DOWN
routine_pass dry > "$OUT"
check "routine dry pass reports docker down" grep -q "docker daemon not reachable" "$OUT"
routine_pass run
check "routine run pass journals docker down" grep -q "skip: docker daemon" "$FAKE_LOG"
unset FAKE_DOCKER_DOWN
fresh
dry_run > "$OUT"
check "dry_run prints the root free line" grep -q "root free:" "$OUT"
FAKE_DF_BAD=1 export FAKE_DF_BAD
dry_run > "$OUT"
check "dry_run reports unknown free space" grep -q "root free: unknown" "$OUT"
unset FAKE_DF_BAD

fresh
set_free 50
check "take_prune_slot grants a slot on a fresh box" take_prune_slot
check_not "take_prune_slot refuses a second slot inside the interval" take_prune_slot
fresh
mkdir -p "$STATE_DIR"; echo garbage > "$PRUNE_STAMP"
check "take_prune_slot treats a corrupt stamp as never run" take_prune_slot

fresh
set_free 5
guard_pass
check "guard_pass writes the marker below the floor" [ -e "$MARKER" ]
check "guard_pass prunes once below the floor" grep -q ' image prune -f' "$FAKE_LOG"
fresh
set_free 12
mkdir -p "$(dirname "$LOCK")"
flock "$LOCK" -c 'sleep 3' &
holder=$!
for _ in $(seq 50); do flock -n "$LOCK" -c true 2>/dev/null || break; sleep 0.1; done
guard_pass > "$OUT" 2>&1
wait "$holder" 2>/dev/null
check_not "guard_pass does not prune while the lock is held" grep -q ' image prune -f' "$FAKE_LOG"
fresh
set_free 50
guard_pass
check_not "guard_pass with healthy space runs no prune" grep -q ' image prune' "$FAKE_LOG"
fresh
FAKE_DF_BAD=1 export FAKE_DF_BAD
guard_pass
check_not "guard_pass with unreadable space runs no prune" grep -q ' image prune' "$FAKE_LOG"
unset FAKE_DF_BAD

fresh
run_locked
check "run_locked runs a routine pass when the lock is free" grep -q "docker info" "$FAKE_LOG"

# --- install and uninstall in-process ------------------------------------------
fresh
install_units user
check "install_units user writes the user binary" [ -x "$HOME/.local/bin/$TAG" ]
check "install_units user writes the routine service" [ -f "$HOME/.config/systemd/user/dev-box-disk-hygiene.service" ]
uninstall_units user
check "uninstall_units user removes the binary" [ ! -e "$HOME/.local/bin/$TAG" ]
check "uninstall_units user removes the units" [ ! -e "$HOME/.config/systemd/user/dev-box-disk-hygiene.timer" ]
fresh
install_units system
check "install_units system writes the system binary" [ -x "$ROOT_PREFIX/usr/local/bin/$TAG" ]
uninstall_units system
check "uninstall_units system removes the binary" [ ! -e "$ROOT_PREFIX/usr/local/bin/$TAG" ]
fresh
FAKE_LINGER=no export FAKE_LINGER
install_units user > "$OUT"
check "install_units user prints the owner linger command when linger is off" grep -q 'enable-linger' "$OUT"
unset FAKE_LINGER

# --- main dispatch ------------------------------------------------------------------
fresh
main --dry-run > "$OUT"
check "main --dry-run prints the dry run footer" grep -q 'dry run: nothing was changed' "$OUT"
fresh
main --guard
check "main --guard checks the free space" grep -q "df -P /" "$FAKE_LOG"
fresh
main --run
check "main --run runs a pass" grep -q "docker info" "$FAKE_LOG"
( main bogus ) >/dev/null 2>&1; rc=$?
check "main with an unknown argument exits 2" [ "$rc" -eq 2 ]
( main --install-user ) >/dev/null 2>&1
check "main --install-user installs" [ -x "$HOME/.local/bin/$TAG" ]
( main --uninstall-user ) >/dev/null 2>&1
check "main --uninstall-user uninstalls" [ ! -e "$HOME/.local/bin/$TAG" ]

if [[ $fail -eq 0 ]]; then
  echo "dev-box-disk-hygiene unit tests: all passed"
fi
exit "$fail"
