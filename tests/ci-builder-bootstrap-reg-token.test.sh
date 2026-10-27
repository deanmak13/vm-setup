#!/usr/bin/env bash
# tests/ci-builder-bootstrap-reg-token.test.sh — --reg-token-file registers one
# runner from a pre-minted registration token. Argument and file refusals run
# before anything else; the valid path never mints a token, and the token
# reaches config.sh only through the su stdin script, never through any argv.
set -euo pipefail
BOOTSTRAP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ci-builder-bootstrap.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
TOKEN='fixture-regtoken-7f3a9c'
printf '%s' "$TOKEN" > "$work/reg-600" && chmod 600 "$work/reg-600"
printf '%s' "$TOKEN" > "$work/reg-644" && chmod 644 "$work/reg-644"
ln -s "$work/reg-600" "$work/reg-link"

# run <main args...> — sources the real script, replaces only the root,
# host-identity, package, service and credential boundaries, then dispatches.
run() {
  BOOTSTRAP="$BOOTSTRAP" TEST_ROOT="$work" RUNNER_HOME="$work/home" bash -c '
    source "$BOOTSTRAP"
    require_root() { :; }
    hostname() { printf "vmi3387590\n"; }
    id() { return 0; }
    usermod() { :; }
    apt-get() { echo "FORBIDDEN host package setup"; exit 91; }
    systemctl() { echo "FORBIDDEN service setup"; exit 94; }
    docker() { echo "FORBIDDEN docker setup"; exit 93; }
    curl() { echo "FORBIDDEN token mint" >> "$TEST_ROOT/curl.log"; return 1; }
    su() {
      local command="${*: -1}"
      printf "%s\n" "$*" >> "$TEST_ROOT/su-argv.log"
      if [[ "$command" == /bin/bash ]]; then
        cat >> "$TEST_ROOT/su-stdin.log"
        return 0
      fi
      case "$command" in
        *"mkdir -p"*) mkdir -p "$dir" ;;
        *"curl -fsSL"*)
          printf "#!/bin/sh\nexit 0\n" > "$dir/svc.sh"
          chmod +x "$dir/svc.sh" ;;
        *) echo "unexpected su command"; exit 95 ;;
      esac
    }
    main "$@"
  ' bash "$@"
}

# refuses <message fragment> <main args...> — must exit non-zero with the message.
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
printf 'PASS --reg-token-file refuses missing, symlinked and world-readable files\n'

# (c)-(e) valid mode: no PAT, no mint, token only on stdin.
run --runners-only --runner-repo pneuma-terraformer --reg-token-file "$work/reg-600" \
  > "$work/out" 2>&1
test ! -e "$work/curl.log" || { echo 'FAIL registration token was minted'; exit 1; }
printf 'PASS valid --reg-token-file mode never mints a token and needs no --gh-token-file\n'

grep -qx -- '- ubuntu -s /bin/bash' "$work/su-argv.log" || { echo 'FAIL config step not run via su stdin'; exit 1; }
! grep -q -- "$TOKEN" "$work/su-argv.log" || { echo 'FAIL token value appeared in su argv'; exit 1; }
! grep -q -- "$TOKEN" "$work/out" || { echo 'FAIL token value appeared in output'; exit 1; }
printf 'PASS the token is absent from every su argv and from the output\n'

grep -qx -- "export ACTIONS_RUNNER_INPUT_TOKEN='$TOKEN'" "$work/su-stdin.log" \
  || { echo 'FAIL stdin does not carry ACTIONS_RUNNER_INPUT_TOKEN'; exit 1; }
printf 'PASS stdin carries the token as ACTIONS_RUNNER_INPUT_TOKEN\n'

grep -q -- './config.sh --unattended' "$work/su-stdin.log" || { echo 'FAIL config.sh call missing'; exit 1; }
grep -q -- "--name 'pneuma-terraformer-contabo'" "$work/su-stdin.log" || { echo 'FAIL --name missing'; exit 1; }
grep -q -- "--labels 'self-hosted,ci-builder'" "$work/su-stdin.log" || { echo 'FAIL --labels missing'; exit 1; }
! grep -q -- '--token' "$work/su-stdin.log" || { echo 'FAIL config.sh still receives --token'; exit 1; }
printf 'PASS config.sh carries the unchanged flags and no --token\n'

! grep -q 'reaper' "$work/out" || { echo 'FAIL reaper watchdog ran in runners-only mode'; exit 1; }
printf 'PASS runners-only reg-token mode skips the watchdog path\n'
