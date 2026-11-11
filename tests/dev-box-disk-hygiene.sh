#!/usr/bin/env bash
# tests/dev-box-disk-hygiene.sh - behaviour tests for dev-box-disk-hygiene.sh, run as
# child processes. The shared sandbox lives in dev-box-disk-hygiene.lib.sh. The
# in-process unit layer is dev-box-disk-hygiene.test.sh (measured by kcov).
# Assertions are branch-free: a failed check sets fail=1 and the run exits 1.

REPO_TESTS=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=dev-box-disk-hygiene.lib.sh
source "$REPO_TESTS/dev-box-disk-hygiene.lib.sh"

# --- healthy disk, nothing to select: every selection is a no-op -----------
reset_fakes
call --run
check "--run exits 0" [ "$rc" -eq 0 ]
expect "empty selections remove no container" '^docker rm ' 0
expect "empty selections remove no volume" '^docker volume rm ' 0
expect "image prune is dangling-only" '^docker image prune -f$' 1
expect "no prune ever uses -a or --all" 'prune.* (-a|--all)' 0
expect "healthy disk raises no warning" 'daemon.warning' 0
check "healthy disk writes no marker" [ ! -e "$MARKER" ]

# --- containers: explicit selection, aged from when they stopped -------------
reset_fakes
add_container "$(hex 1)" tst-pg-run1 exited "$(docker_stamp 3 days)"                  # stopped 3 days ago
add_container "$(hex 2)" web-1 exited "$(docker_stamp 3 days)" "com.docker.compose.project=kodus"
add_container "$(hex 3)" kodus-api exited "$(docker_stamp 3 days)"
add_container "$(hex 4)" db_kodus_main exited "$(docker_stamp 3 days)"
add_container "$(hex 5)" coding-gateway-old created "$(docker_stamp 3 days)"
add_container "$(hex 6)" rabbitmq-prod exited "$(docker_stamp 3 days)"
add_container "$(hex 7)" pg-young exited "$(docker_stamp 1 hours)"
add_container "$(hex 8)" pg-dead dead "$(docker_stamp 3 days)"
call --dry-run
expect_out "dry run counts two containers" '^containers: 2 would be removed' 1
expect_out "dry run names the selected containers" '^  tst-pg-run1$' 1
expect_out "dry run names the dead container" '^  pg-dead$' 1
expect "dry run removes no container" '^docker rm ' 0
call --run
expect "one batched rm call for the selection" '^docker rm ' 1
expect "old unlabelled container is removed" "^docker rm -- .*$(hex 1)( |\$)" 1
expect "dead container is removed" "^docker rm -- .*$(hex 8)( |\$)" 1
expect "compose-labelled container kept" "^docker rm .*$(hex 2)" 0
expect "kodus keep-pattern container kept" "^docker rm .*$(hex 3)" 0
expect "db_kodus keep-pattern container kept" "^docker rm .*$(hex 4)" 0
expect "coding-gateway keep-pattern container kept" "^docker rm .*$(hex 5)" 0
expect "rabbitmq-prod keep-pattern container kept" "^docker rm .*$(hex 6)" 0
expect "young container kept" "^docker rm .*$(hex 7)" 0
expect "container rm never forces" '^docker rm -f' 0
expect "removed container is journaled" 'logger -t dev-box-disk-hygiene -- removed container' 2

# --- a container created long ago but stopped recently is kept ----------------
reset_fakes
add_volume "$(hex 20)" 1 "$(rfc_stamp 3 days)" 2GB
add_container "$(hex 20)" pg-hand-started exited "$(docker_stamp 3 days)" "" "$(rfc_stamp 10 minutes)" "$(mount_of "$(hex 20)")"
call --run
expect "container stopped 10 minutes ago is kept" "^docker rm " 0
expect "its data volume is kept while it is stopped recently" "^docker volume rm .*$(hex 20)" 0

# --- grace: the volume of a container removed in this pass survives until the grace ends
reset_fakes
add_volume "$(hex 21)" 1 "$(rfc_stamp 3 days)" 2GB
add_container "$(hex 21)" pg-old-stopped exited "$(docker_stamp 3 days)" "" "$(rfc_stamp 25 hours)" "$(mount_of "$(hex 21)")"
call --run
expect "stopped 25 hours ago: container removed" "^docker rm .*$(hex 21)" 1
expect "its volume is not removed in the pass that removed the container" "^docker volume rm .*$(hex 21)" 0
check "grace window recorded the volume" grep -q "$(hex 21) " "$GRACE_FILE"
call --run
expect "its volume is still in grace on the next pass" "^docker volume rm .*$(hex 21)" 0
sed -i "s/ [0-9]*$/ 0/" "$GRACE_FILE"
call --run
expect "after the grace the volume is removed" "^docker volume rm .*$(hex 21)" 1

# --- created-state container that never ran ages from its creation ----------
reset_fakes
add_container "$(hex 22)" never-ran created "$(docker_stamp 3 days)"
call --run
expect "never-started container ages from creation and is removed" "^docker rm .*$(hex 22)" 1

# --- container removal failure is journaled, the pass continues --------------
reset_fakes
add_container "$(hex 1)" tst-pg-a exited "$(docker_stamp 3 days)"
FAKE_RM_FAIL=1 export FAKE_RM_FAIL
call --run
expect "failed container rm is journaled" 'container rm: Error' 1
expect "unremoved selection is journaled" '1 selected item\(s\) not removed' 1
unset FAKE_RM_FAIL

# --- volumes: anonymous, dangling, old enough -------------------------------
reset_fakes
add_volume "$(hex 10)" 0 "$(rfc_stamp 3 days)" 2GB                 # selected
add_volume "$(hex 11)" 0 "$(rfc_stamp 1 hours)" 1GB                 # younger than 2h
add_volume pgdata 0 "$(rfc_stamp 3 days)" 3GB                       # named
add_volume "$(hex 12)" 1 "$(rfc_stamp 3 days)" 4GB                  # in use
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
expect "dry run removes no pytest dir" '^docker (rm|volume rm|image prune) |^rm ' 0
check "dry run kept pytest-0" [ -d "$PYTEST_BASE/pytest-0" ]
call --run
check "old unreferenced pytest dir removed" [ ! -e "$PYTEST_BASE/pytest-0" ]
check "process-referenced pytest dir kept" [ -d "$PYTEST_BASE/pytest-1" ]
check "young pytest dir kept" [ -d "$PYTEST_BASE/pytest-2" ]
check "pytest-current symlink untouched" [ -L "$PYTEST_BASE/pytest-current" ]
expect "pytest removal is journaled" 'logger -t dev-box-disk-hygiene -- removed pytest temp dir' 1
unset FAKE_PGREP_HIT

# --- one process scan per pass, however many candidates ----------------------
reset_fakes
for i in 1 2 3 4 5; do add_pytest_dir "pytest-$i" 5hours; done
call --run
expect "five candidates cause one process scan" '^ps ' 1

# --- basetemps: pytest layout under a claude scratch root --------------------
reset_fakes
BT=$T/root/tmp/claude-$(id -u)/proj
mkdir -p "$BT/test_flow0" "$BT/test_flow1"
chmod 755 "$BT" "$BT/test_flow0" "$BT/test_flow1"     # pytest makes basetemps 700; pin the test's mode
echo x > "$BT/test_flow0/a.txt"; echo x > "$BT/test_flow1/b.txt"
ln -s test_flow1 "$BT/test_flowcurrent"
touch -d '3 days ago' "$BT/test_flow0/a.txt" "$BT/test_flow0" "$BT/test_flow1/b.txt" "$BT/test_flow1" "$BT"
touch -h -d '3 days ago' "$BT/test_flowcurrent"
# A young basetemp and one with a foreign entry must survive.
YB=$T/root/tmp/claude-$(id -u)/young; mkdir -p "$YB/test_y0"; echo x > "$YB/test_y0/y"; ln -s test_y0 "$YB/test_ycurrent"
FB=$T/root/tmp/claude-$(id -u)/foreign; mkdir -p "$FB/test_f0" "$FB/test_f1"; echo x > "$FB/notes.txt"
ln -s test_f1 "$FB/test_fcurrent"; touch -d '3 days ago' "$FB" "$FB/test_f0" "$FB/test_f1" "$FB/notes.txt"
call --dry-run
expect_out "dry run counts one basetemp" '^basetemps: 1 would be removed' 1
call --run
check "real-looking basetemp removed" [ ! -e "$BT" ]
check "young basetemp kept" [ -d "$YB" ]
check "basetemp with a foreign entry kept" [ -d "$FB" ]

# --- basetemp roots and ancestors must be private; root never walks user trees ----
reset_fakes
BTA=$BASETEMP_UID_ROOT/proj; mkdir -p "$BTA/test_a0" "$BTA/test_a1"; chmod 755 "$BTA" "$BTA/test_a0" "$BTA/test_a1"
echo x > "$BTA/test_a0/f"; ln -s test_a1 "$BTA/test_acurrent"
touch -d '3 days ago' "$BTA/test_a0/f" "$BTA/test_a0" "$BTA/test_a1" "$BTA"; touch -h -d '3 days ago' "$BTA/test_acurrent"
FAKE_STAT_UID=0 export FAKE_STAT_UID
call --dry-run
expect_out "a basetemp root owned by another uid is refused" 'unsafe-root' 1
expect_out "no basetemp is selected under a foreign-owned root" '^basetemps: 0 would be removed' 1
call --run
check "basetemp under a foreign-owned root kept" [ -d "$BTA" ]
unset FAKE_STAT_UID

reset_fakes
BTM=$BASETEMP_UID_ROOT/mid; BTC=$BTM/proj; mkdir -p "$BTC/test_c0" "$BTC/test_c1"
chmod 775 "$BTM"; chmod 755 "$BTC" "$BTC/test_c0" "$BTC/test_c1"
echo x > "$BTC/test_c0/f"; ln -s test_c1 "$BTC/test_ccurrent"
touch -d '3 days ago' "$BTC/test_c0/f" "$BTC/test_c0" "$BTC/test_c1" "$BTC"; touch -h -d '3 days ago' "$BTC/test_ccurrent"
call --dry-run
expect_out "a group-writable ancestor makes the candidate unsafe" 'unsafe-ancestor' 1
call --run
check "candidate under a group-writable ancestor kept" [ -d "$BTC" ]
expect "the unsafe keep is journaled" 'basetemps kept .*unsafe-ancestor' 1

reset_fakes
add_pytest_dir pytest-0 5hours
BTR0=$BASETEMP_UID_ROOT/proj; mkdir -p "$BTR0/test_r0" "$BTR0/test_r1"; chmod 755 "$BTR0" "$BTR0/test_r0" "$BTR0/test_r1"
echo x > "$BTR0/test_r0/f"; ln -s test_r1 "$BTR0/test_rcurrent"
touch -d '3 days ago' "$BTR0/test_r0/f" "$BTR0/test_r0" "$BTR0/test_r1" "$BTR0"; touch -h -d '3 days ago' "$BTR0/test_rcurrent"
FAKE_UID=0 export FAKE_UID
call --dry-run
expect_out "root skips the pytest pass" 'pytest: skipped \(running as root' 1
expect_out "root skips the basetemp pass" 'basetemps: skipped \(running as root' 1
expect_out "root skips the release pass" 'releases: skipped \(running as root' 1
call --run
check "root leaves a user's pytest dir alone" [ -d "$PYTEST_BASE/pytest-0" ]
check "root leaves a user's basetemp alone" [ -d "$BTR0" ]
expect "root journals the skipped passes" 'pass skipped: running as root' 3
unset FAKE_UID

# --- ownership and symlink discipline on removal -----------------------------
reset_fakes
add_pytest_dir pytest-0 5hours
FAKE_STAT_UID=0 export FAKE_STAT_UID
call --dry-run
expect_out "foreign-owned pytest base skips the pass" 'pytest: skipped .*not owned' 1
call --run
check "pytest dir kept under a foreign-owned base" [ -d "$PYTEST_BASE/pytest-0" ]
expect "foreign-owned pytest base is journaled as skipped" 'pytest pass skipped' 1
unset FAKE_STAT_UID

reset_fakes
add_pytest_dir pytest-0 5hours
chmod 775 "$PYTEST_BASE"
call --run
check "pytest dir kept under a group-writable base" [ -d "$PYTEST_BASE/pytest-0" ]
expect "group-writable pytest base is journaled as skipped" 'pytest pass skipped' 1

reset_fakes
mkdir -p "$T/outside"; echo keep > "$T/outside/keep.txt"; touch -d '5 hours ago' "$T/outside/keep.txt" "$T/outside"
ln -s "$T/outside" "$PYTEST_BASE/pytest-9"
call --run
check "symlink candidate kept" [ -L "$PYTEST_BASE/pytest-9" ]
check "symlink candidate target untouched" [ -f "$T/outside/keep.txt" ]

reset_fakes
mkdir -p "$T/outside"; echo keep > "$T/outside/keep.txt"; touch -d '5 hours ago' "$T/outside/keep.txt" "$T/outside"
add_pytest_dir pytest-0 5hours
ln -s "$T/outside/keep.txt" "$PYTEST_BASE/pytest-0/link.txt"
touch -h -d '5 hours ago' "$PYTEST_BASE/pytest-0/link.txt"
touch -d '5 hours ago' "$PYTEST_BASE/pytest-0"
call --run
check "candidate with inner symlink removed" [ ! -e "$PYTEST_BASE/pytest-0" ]
check "symlink target outside the candidate untouched" [ -f "$T/outside/keep.txt" ]

reset_fakes
BT2=$T/root/tmp/claude-$(id -u)/gp; mkdir -p "$BT2/test_g0"; echo x > "$BT2/test_g0/f"
chmod 775 "$BT2/test_g0"; ln -s test_g0 "$BT2/test_gcurrent"; touch -d '3 days ago' "$BT2"/test_g0/f "$BT2/test_g0" "$BT2"
call --run
check "basetemp with a group-writable dir refused whole" [ -f "$BT2/test_g0/f" ]

# --- gateway releases ------------------------------------------------------
reset_fakes
add_release 1 4hours                    # active (unit): kept
add_release 2 5hours                    # referenced by a process: kept
add_release 3 1hours                    # newest other: kept
add_release 4 2hours                    # second newest other: kept
add_release 5 3hours                    # third other: removed
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
export FAKE_PGREP_HIT="$RELDIR/$(rhex 2)"
call --dry-run
expect_out "dry run counts one superseded release" '^releases: 1 would be removed' 1
expect_out "dry run keeps the active release" 'active=1' 1
check "dry run removed no release" [ -d "$RELDIR/$(rhex 5)" ]
call --run
check "superseded read-only release removed" [ ! -e "$RELDIR/$(rhex 5)" ]
for n in 1 2 3 4; do check "release $n kept" [ -d "$RELDIR/$(rhex "$n")" ]; done
expect "release removal is journaled" 'logger -t dev-box-disk-hygiene -- removed gateway release' 1
unset FAKE_PGREP_HIT

reset_fakes
add_release 1 4hours
add_release 2 5hours
add_release 3 3hours
add_release 4 6hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 5 7hours
ln -s "$RELDIR/$(rhex 2)" "$(dirname "$RELDIR")/current"
call --dry-run
expect_out "release pointed at by a current link is protected; the oldest unprotected is selected" 'releases: 1 would be removed' 1
call --run
check "release pointed at by a current link survives" [ -d "$RELDIR/$(rhex 2)" ]
check "a release that would otherwise be a newest-two keeper is kept" [ -d "$RELDIR/$(rhex 4)" ]
check "the oldest unprotected release is removed" [ ! -e "$RELDIR/$(rhex 5)" ]
rm -f -- "$(dirname "$RELDIR")/current"

reset_fakes
call --dry-run
expect_out "missing release directory is silent" '^releases:' 0
add_release 1 1hours
call --dry-run
expect_out "missing unit skips the release pass" '^releases: skipped \(.*not found' 1
check "release kept without a unit" [ -d "$RELDIR/$(rhex 1)" ]

reset_fakes
add_release 1 4hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 5hours
add_release 3 3hours
add_release 4 6hours
chmod 775 "$RELDIR/$(rhex 4)/bin"
call --run
check "group-writable release tree refused whole" [ -f "$RELDIR/$(rhex 4)/bin/gateway" ]
expect "group-writable tree refusal is journaled" 'refusing to remove .*group/other-writable' 1

reset_fakes
add_release 1 4hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 5hours
add_release 3 3hours
add_release 4 6hours
FAKE_FOREIGN=1 export FAKE_FOREIGN
call --run
check "tree with a foreign-owned entry refused whole" [ -f "$RELDIR/$(rhex 4)/bin/gateway" ]
expect "foreign-owned entry refusal is journaled" 'owned by another uid' 1
unset FAKE_FOREIGN

reset_fakes
add_release 1 4hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 5hours
add_release 3 3hours
add_release 4 6hours
FAKE_STAT_UID=0 export FAKE_STAT_UID
call --dry-run
expect_out "foreign-owned releases base skips the pass" 'releases: skipped .*owned by' 1
call --run
check "release kept under a foreign-owned base" [ -d "$RELDIR/$(rhex 4)" ]
unset FAKE_STAT_UID

# --- empty selections never run a removal ----------------------------------
reset_fakes
add_container "$(hex 2)" web-1 exited "$(docker_stamp 3 days)" "com.docker.compose.project=kodus"
add_volume "$(hex 11)" 0 "$(rfc_stamp 1 hours)" 1GB
add_pytest_dir pytest-0 10minutes
call --run
check "all-kept run exits 0" [ "$rc" -eq 0 ]
expect "all-kept run removes no container" '^docker rm ' 0
expect "all-kept run removes no volume" '^docker volume rm ' 0
check "young pytest dir kept on empty selection" [ -d "$PYTEST_BASE/pytest-0" ]

# --- dry run mutates nothing and reports every pass --------------------------
reset_fakes
add_container "$(hex 1)" tst-pg-a exited "$(docker_stamp 3 days)"
add_volume "$(hex 10)" 0 "$(rfc_stamp 3 days)" 2GB
add_pytest_dir pytest-0 5hours
add_release 1 4hours
mkdir -p "$(dirname "$UNIT")"
printf 'ExecStart=%s/%s/bin/gateway\n' "$RELDIR" "$(rhex 1)" > "$UNIT"
add_release 2 3hours
call --dry-run
check "--dry-run exits 0" [ "$rc" -eq 0 ]
expect "dry run calls no removal" '^docker (rm|volume rm|image prune|container prune|volume prune) ' 0
expect "dry run journals nothing" 'logger' 0
expect "dry run calls no rm" '^rm ' 0
expect "dry run writes no grace state" 'docker rm' 0
check "dry run wrote no grace file" [ ! -e "$GRACE_FILE" ]
expect_out "dry run reports containers" '^containers: 1 would be removed' 1
expect_out "dry run reports volumes" '^volumes: 1 would be removed \(2.0GB\)' 1
expect_out "dry run reports pytest" '^pytest: 1 would be removed' 1
expect_out "dry run reports releases" '^releases: 0 would be removed' 1
expect_out "dry run reports images" '^images: 3 dangling would be pruned' 1
expect_out "dry run says nothing changed" 'dry run: nothing was changed' 1
check "dry run kept the pytest dir" [ -d "$PYTEST_BASE/pytest-0" ]
check "dry run kept the release" [ -d "$RELDIR/$(rhex 2)" ]

# --- percentage guard boundaries (1000 GiB disk) ---------------------------
reset_fakes
set_free 15
call --guard
expect "15% free runs no prune" ' image prune ' 0
expect "15% free raises no warning" 'daemon.warning' 0
check "15% free writes no marker" [ ! -e "$MARKER" ]

reset_fakes
set_free 12
call --guard
expect "12% free warns once" 'daemon.warning' 1
expect "12% free prunes immediately" ' image prune -f' 1
expect "12% free does not write the low marker" 'dev-box disk LOW' 0
check "12% free writes no marker" [ ! -e "$MARKER" ]

reset_fakes
set_free 5
call --guard
expect "5% free warns on prune and on low space" 'daemon.warning' 2
expect "5% free prunes immediately" ' image prune -f' 1
expect "5% free alerts once on entry" 'dev-box disk LOW' 1
check "5% free writes the marker" [ -e "$MARKER" ]
call --guard
expect "marker alert is not repeated while still low" 'dev-box disk LOW' 1
check "marker kept while still low" [ -e "$MARKER" ]
set_free 50
call --guard
check "marker cleared after recovery" [ ! -e "$MARKER" ]

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
check "25 GiB free writes the marker" [ -e "$MARKER" ]

reset_fakes
FAKE_TOTAL_GB=387 FAKE_FREE_GB=45 export FAKE_TOTAL_GB FAKE_FREE_GB     # 11.6% free, 45 GiB
call --guard
expect "45 GiB of 387 prunes on the percent floor only" 'daemon.warning' 1

# --- hung docker: the alert still fires and the run ends within its timeout ---
reset_fakes
set_free 5
FAKE_DOCKER_HANG=1 export FAKE_DOCKER_HANG
start=$SECONDS
call --guard
elapsed=$(( SECONDS - start ))
check "guard with a hung docker exits 0" [ "$rc" -eq 0 ]
check "guard with a hung docker ends within its timeout" [ "$elapsed" -lt 60 ]
expect "hung docker still raises the low-space alert" 'dev-box disk LOW' 1
check "hung docker still writes the marker" [ -e "$MARKER" ]
expect "hung docker runs no prune" ' image prune ' 0
unset FAKE_DOCKER_HANG

# --- concurrent pass: a second guard does not prune while the lock is held ---
reset_fakes
set_free 5
mkdir -p "$(dirname "$LOCK")"
flock "$LOCK" -c 'sleep 4' &
holder=$!
for _ in $(seq 50); do flock -n "$LOCK" -c true 2>/dev/null || break; sleep 0.1; done
call --guard
expect "concurrent guard does not prune" ' image prune ' 0
expect "concurrent guard still raises the alert" 'dev-box disk LOW' 1
expect "concurrent guard logs the skipped prune" 'prune skipped' 1
wait "$holder" 2>/dev/null

# --- below-floor twice within the interval: one prune -----------------------
reset_fakes
set_free 5
call --guard
call --guard
expect "two below-floor guards within the interval prune once" ' image prune -f' 1
expect "second guard logs the skipped prune" 'prune skipped' 1
expect "the alert is still raised on each guard run" 'dev-box disk LOW' 1

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
check "--run exits 0 after failed prune" [ "$rc" -eq 0 ]
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

# --- install into a temp root (system) and uninstall -------------------------
reset_fakes
call --install
check "--install exits 0" [ "$rc" -eq 0 ]
check "system binary installed" [ -x "$T/root/usr/local/bin/dev-box-disk-hygiene" ]
check "installed copy matches the script" cmp -s "$SCRIPT" "$T/root/usr/local/bin/dev-box-disk-hygiene"
UNITS="$T/root/etc/systemd/system"
for f in dev-box-disk-hygiene.service dev-box-disk-hygiene.timer \
         dev-box-disk-hygiene-guard.service dev-box-disk-hygiene-guard.timer; do
  check "system unit $f installed" [ -f "$UNITS/$f" ]
done
grep -qx "ExecStart=$T/root/usr/local/bin/dev-box-disk-hygiene --run" "$UNITS/dev-box-disk-hygiene.service" || { echo "FAIL: routine ExecStart" >&2; fail=1; }
grep -qx "ExecStart=$T/root/usr/local/bin/dev-box-disk-hygiene --guard" "$UNITS/dev-box-disk-hygiene-guard.service" || { echo "FAIL: guard ExecStart" >&2; fail=1; }
grep -qx 'OnUnitActiveSec=15min' "$UNITS/dev-box-disk-hygiene.timer" || { echo "FAIL: routine interval" >&2; fail=1; }
grep -qx 'OnUnitActiveSec=1min' "$UNITS/dev-box-disk-hygiene-guard.timer" || { echo "FAIL: guard interval" >&2; fail=1; }
for f in dev-box-disk-hygiene.service dev-box-disk-hygiene-guard.service; do
  grep -qx 'Nice=19' "$UNITS/$f" || { echo "FAIL: Nice=19 missing from $f" >&2; fail=1; }
  grep -qx 'IOSchedulingClass=idle' "$UNITS/$f" || { echo "FAIL: IOSchedulingClass missing from $f" >&2; fail=1; }
  grep -qE '^TimeoutStartSec=[0-9a-z]+$' "$UNITS/$f" || { echo "FAIL: TimeoutStartSec missing from $f" >&2; fail=1; }
done
expect "system install reloads systemd" '^systemctl daemon-reload$' 1
expect "system install enables both timers" '^systemctl enable --now dev-box-disk-hygiene.timer dev-box-disk-hygiene-guard.timer$' 1
expect "system install runs no removal" '^docker (rm|volume rm|image prune) ' 0
call --uninstall
check "--uninstall exits 0" [ "$rc" -eq 0 ]
check "system binary removed" [ ! -e "$T/root/usr/local/bin/dev-box-disk-hygiene" ]
check "system units removed" [ ! -e "$UNITS/dev-box-disk-hygiene.timer" ]
expect "system uninstall disables the timers" '^systemctl disable --now dev-box-disk-hygiene.timer dev-box-disk-hygiene-guard.timer$' 1

# --- install as the user (no root, systemd USER timers) -----------------------
reset_fakes
call --install-user
check "--install-user exits 0" [ "$rc" -eq 0 ]
UBIN="$HOME/.local/bin/dev-box-disk-hygiene"
check "user binary installed" [ -x "$UBIN" ]
check "user-installed copy matches the script" cmp -s "$SCRIPT" "$UBIN"
UUNITS="$HOME/.config/systemd/user"
grep -qx "ExecStart=$UBIN --run" "$UUNITS/dev-box-disk-hygiene.service" || { echo "FAIL: user routine ExecStart" >&2; fail=1; }
grep -qx "ExecStart=$UBIN --guard" "$UUNITS/dev-box-disk-hygiene-guard.service" || { echo "FAIL: user guard ExecStart" >&2; fail=1; }
expect "user install reloads user systemd" '^systemctl --user daemon-reload$' 1
expect "user install enables both user timers" '^systemctl --user enable --now dev-box-disk-hygiene.timer dev-box-disk-hygiene-guard.timer$' 1
expect "user install never uses root systemd" '^systemctl (daemon-reload|enable)' 0
expect_out "lingering on is reported" 'lingering is on' 1
reset_fakes
FAKE_LINGER=no export FAKE_LINGER
call --install-user
expect_out "lingering off prints the one owner command" "sudo loginctl enable-linger $(id -un)" 1
check "user install completed with linger off" [ -x "$UBIN" ]
unset FAKE_LINGER
call --uninstall-user
check "--uninstall-user exits 0" [ "$rc" -eq 0 ]
check "user binary removed" [ ! -e "$UBIN" ]
check "user units removed" [ ! -e "$UUNITS/dev-box-disk-hygiene-guard.timer" ]
expect "user uninstall disables the user timers" '^systemctl --user disable --now' 1

# --- usage -------------------------------------------------------------------
call bogus
check "unknown argument exits 2" [ "$rc" -eq 2 ]

if [[ $fail -eq 0 ]]; then
  echo "dev-box-disk-hygiene tests: all passed"
fi
exit "$fail"
