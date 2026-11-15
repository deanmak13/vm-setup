#!/usr/bin/env bash
# host/gate-durations-dirs.sh — create the per-repo directories the nightlies publish test durations into.
#   bash gate-durations-dirs.sh BASE OWNER REPOS_FILE
# BASE is the gate base dir (/var/lib/pneuma-gate), OWNER the CI runner user (it writes), REPOS_FILE the
# data list (gate-durations-repos.txt: one repo per line, '#' comments). Idempotent: `install -d` converges
# owner and mode on every run. BASE/durations is 0755; each repo dir is OWNER:OWNER 0755, so the runner
# user publishes and everyone else (the root-run gate runner, the gate units) reads; nobody else writes.
set -euo pipefail
BASE="${1:?usage: gate-durations-dirs.sh BASE OWNER REPOS_FILE}"
OWNER="${2:?owner}"
LIST="${3:?repos file}"
[ -f "$LIST" ] || { echo "gate-durations-dirs: no repos file $LIST" >&2; exit 1; }
id "$OWNER" >/dev/null 2>&1 || { echo "gate-durations-dirs: owner '$OWNER' does not exist" >&2; exit 1; }
repos=()
while IFS= read -r line; do
  line="${line%%#*}"; line="${line//[[:space:]]/}"
  [ -n "$line" ] || continue
  [[ "$line" =~ ^[a-z0-9][a-z0-9._-]*$ && "$line" != *..* ]] || { echo "gate-durations-dirs: bad repo name '$line'" >&2; exit 1; }
  repos+=("$line")
done < "$LIST"
[ "${#repos[@]}" -gt 0 ] || { echo "gate-durations-dirs: no repos listed in $LIST" >&2; exit 1; }
# On the host this runs as root, so BASE and durations/ end up root-owned; unprivileged (tests) they are the caller's.
me="$(id -un)"
install -d -o "$me" -g "$(id -gn "$me")" -m 0755 "$BASE" "$BASE/durations"
for r in "${repos[@]}"; do
  install -d -o "$OWNER" -g "$(id -gn "$OWNER")" -m 0755 "$BASE/durations/$r"
done
printf 'gate-durations: %s\n' "${repos[*]}"
