#!/usr/bin/env bash
# tests/ci-builder-bootstrap-reg-token.test.sh — --reg-token-file registers one
# runner from a pre-minted token. Argument, file and token-shape refusals run
# before any registration step; the valid path never mints a token, and the
# token reaches config.sh as data on the inner shell's stdin, never in argv.
set -euo pipefail
BOOTSTRAP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ci-builder-bootstrap.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
TOKEN='fixture-regtoken-7f3a9c'
printf '%s' "$TOKEN" > "$work/reg-600" && chmod 600 "$work/reg-600"
printf '%s' "$TOKEN" > "$work/reg-644" && chmod 644 "$work/reg-644"
printf '%s' 'fixture-regtoken-$(touch PWNED)' > "$work/reg-subst" && chmod 600 "$work/reg-subst"
printf '%s' 'fixture-regtoken-7f3a9c"x' > "$work/reg-quote" && chmod 600 "$work/reg-quote"
ln -s "$work/reg-600" "$work/reg-link"
printf 'x' > "$work/pat"
# A fixture config.sh: records the token it sees in its environment and the
# argv it was started with. The real bash -s inner shell runs it.
cat > "$work/config-fixture.sh" <<'FIXTURE'
#!/bin/bash
printf '%s' "${ACTIONS_RUNNER_INPUT_TOKEN:-}" > "$TEST_ROOT/config-env.log"
printf '%s\n' "$*" > "$TEST_ROOT/config-argv.log"
FIXTURE

# run <main args...> — sources the real script, replaces only the root,
# host-identity, package, service, ownership and credential boundaries, then
# dispatches. The inner shell of the su step is the real bash -s.
run() {
  BOOTSTRAP="$BOOTSTRAP" TEST_ROOT="$work" RUNNER_HOME="$work/home" \
    TEST_UID="${TEST_UID:-0}" TEST_MINT_JSON="${TEST_MINT_JSON:-}" bash -c '
    source "$BOOTSTRAP"
    require_root() { :; }
    hostname() { printf "vmi3387590\n"; }
    id() { return 0; }
    usermod() { :; }
    apt-get() { echo "FORBIDDEN host package setup"; exit 91; }
    systemctl() { echo "FORBIDDEN service setup"; exit 94; }
    docker() { echo "FORBIDDEN docker setup"; exit 93; }
    stat() {
      # File ownership is root-only; the test stands in for the owner query.
      if [[ "$*" == *%u* ]]; then printf "%s\n" "$TEST_UID"; else command stat "$@"; fi
    }
    curl() {
      if [[ -n "$TEST_MINT_JSON" ]]; then printf "%s\n" "$TEST_MINT_JSON"; return 0; fi
      echo "FORBIDDEN token mint" >> "$TEST_ROOT/curl.log"; return 1
    }
    su() {
      local command="${*: -1}"
      printf "%s\n" "$*" >> "$TEST_ROOT/su-argv.log"
      case "$command" in
        *"./config.sh"*) tee -a "$TEST_ROOT/su-stdin.log" | bash -c "$command" ;;
        *"mkdir -p"*) mkdir -p "$dir" ;;
        *"curl -fsSL"*)
          printf "#!/bin/sh\nexit 0\n" > "$dir/svc.sh"
          chmod +x "$dir/svc.sh"
          cp "$TEST_ROOT/config-fixture.sh" "$dir/config.sh"
          chmod +x "$dir/config.sh" ;;
        *) echo "unexpected su command"; exit 95 ;;
      esac
    }
    main "$@"
  ' bash "$@"
}

# refuses <message fragment> <main args...> — must exit non-zero with the
# message, and must not reach any registration step.
refuses() {
  local want=$1 out
  shift
  if out=$(run "$@" 2>&1); then
    echo "FAIL accepted: $*"; exit 1
  fi
  grep -q -- "$want" <<< "$out" || { echo "FAIL wrong refusal for: $* :: $out"; exit 1; }
  test ! -e "$work/su-argv.log" || { echo "FAIL refusal reached registration: $*"; exit 1; }
}

# (a) argument combinations
refuses "--runner-repo requires --runners-only" \
  --reg-token-file "$work/reg-600" --runner-repo pneuma-terraformer
refuses "requires --runners-only and --runner-repo" \
  --runners-only --reg-token-file "$work/reg-600"
refuses "requires --runners-only and --runner-repo" \
  --reg-token-file "$work/reg-600"
refuses "exactly one inventory row" \
  --runners-only --runner-repo pneuma-engine --reg-token-file "$work/reg-600"
printf 'PASS --reg-token-file refuses every invalid argument combination\n'

# (b) file checks
refuses "must be a regular file" \
  --runners-only --runner-repo pneuma-terraformer --reg-token-file "$work/missing"
refuses "not a symlink" \
  --runners-only --runner-repo pneuma-terraformer --reg-token-file "$work/reg-link"
refuses "mode 0600 or 0400" \
  --runners-only --runner-repo pneuma-terraformer --reg-token-file "$work/reg-644"
TEST_UID=1000 refuses "owned by root" \
  --runners-only --runner-repo pneuma-terraformer --reg-token-file "$work/reg-600"
printf 'PASS --reg-token-file refuses missing, symlinked, world-readable and non-root-owned files\n'

# (c) token shape: a quote or a command substitution is refused, from the file
# and from the mint path, before any registration step runs.
refuses "malformed" \
  --runners-only --runner-repo pneuma-terraformer --reg-token-file "$work/reg-subst"
refuses "malformed" \
  --runners-only --runner-repo pneuma-terraformer --reg-token-file "$work/reg-quote"
test ! -e "$work/PWNED" || { echo 'FAIL substitution was evaluated'; exit 1; }
TEST_MINT_JSON='{"token":"fixture-regtoken-$(touch PWNED)"}' \
  run --runners-only --runner-repo pneuma-terraformer --gh-token-file "$work/pat" \
  > "$work/mint-out" 2>&1 && { echo 'FAIL minted malformed token accepted'; exit 1; }
grep -q 'malformed' "$work/mint-out" || { echo 'FAIL minted token not refused as malformed'; exit 1; }
test ! -e "$work/config-argv.log" || { echo 'FAIL config.sh ran with a malformed minted token'; exit 1; }
test ! -e "$work/PWNED" || { echo 'FAIL minted substitution was evaluated'; exit 1; }
printf 'PASS a token with a quote or $( is refused from both the file and the mint path\n'

# (d) valid mode: no PAT, no mint, token only as stdin data and config.sh env.
rm -f "$work"/su-argv.log "$work"/su-stdin.log "$work"/config-*.log "$work"/curl.log
run --runners-only --runner-repo pneuma-terraformer --reg-token-file "$work/reg-600" \
  > "$work/out" 2>&1
test ! -e "$work/curl.log" || { echo 'FAIL registration token was minted'; exit 1; }
printf 'PASS valid --reg-token-file mode never mints a token and needs no --gh-token-file\n'

grep -q -- 'IFS= read -r ACTIONS_RUNNER_INPUT_TOKEN' "$work/su-argv.log" || { echo 'FAIL config step not run via su'; exit 1; }
! grep -q -- "$TOKEN" "$work/su-argv.log" || { echo 'FAIL token value appeared in su argv'; exit 1; }
! grep -q -- "$TOKEN" "$work/out" || { echo 'FAIL token value appeared in output'; exit 1; }
printf 'PASS the token is absent from every argv and from the output\n'

test "$(grep -c -- "$TOKEN" "$work/su-stdin.log")" -eq 1 || { echo 'FAIL token outside its single data line'; exit 1; }
grep -qx -- "$TOKEN" "$work/su-stdin.log" || { echo 'FAIL token not sent as its own data line'; exit 1; }
! grep -q -- "$TOKEN" "$work/su-argv.log" || { echo 'FAIL token written into script text'; exit 1; }
printf 'PASS the token travels as a single stdin data line, not in the script text\n'

test "$(cat "$work/config-env.log")" = "$TOKEN" || { echo 'FAIL config.sh did not receive the token in its environment'; exit 1; }
grep -q -- '--unattended' "$work/config-argv.log" || { echo 'FAIL --unattended missing'; exit 1; }
grep -q -- '--url https://github.com/deanmak13/pneuma-terraformer' "$work/config-argv.log" || { echo 'FAIL --url missing'; exit 1; }
grep -q -- '--name pneuma-terraformer-contabo' "$work/config-argv.log" || { echo 'FAIL --name missing'; exit 1; }
grep -q -- '--labels self-hosted,ci-builder' "$work/config-argv.log" || { echo 'FAIL --labels missing'; exit 1; }
! grep -q -- '--token' "$work/config-argv.log" || { echo 'FAIL config.sh still receives --token'; exit 1; }
! grep -q -- "$TOKEN" "$work/config-argv.log" || { echo 'FAIL token in config.sh argv'; exit 1; }
printf 'PASS config.sh gets the token in its environment only, with unchanged flags and no --token\n'

! grep -q 'reaper' "$work/out" || { echo 'FAIL reaper watchdog ran in runners-only mode'; exit 1; }
printf 'PASS runners-only reg-token mode skips the watchdog path\n'
