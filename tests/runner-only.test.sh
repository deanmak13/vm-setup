#!/usr/bin/env bash
set -euo pipefail
BOOTSTRAP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ci-builder-bootstrap.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'test-token-not-real' > "$work/token"
# Sourcing exposes the shared entry point without running any host setup.
# Replace only credential/root/registration boundaries, then exercise the
# real CLI mode dispatcher. Any whole-host command aborts the test.
BOOTSTRAP="$BOOTSTRAP" TEST_ROOT="$work" bash -euo pipefail -c '
  source "$BOOTSTRAP"
  require_root() { :; }
  hostname() { printf "vmi3387590\n"; }
  register_runners() { printf "registered:%s\n" "$RUNNER_REPO"; }
  apt-get() { echo "FORBIDDEN host package setup"; exit 91; }
  usermod() { echo "FORBIDDEN whole-host setup"; exit 92; }
  docker() { echo "FORBIDDEN docker setup"; exit 93; }
  systemctl() { echo "FORBIDDEN service setup"; exit 94; }
  main --runners-only --runner-repo pneuma-terraformer --gh-token-file "$TEST_ROOT/token"
' > "$work/result"
grep -qx 'registered:pneuma-terraformer' "$work/result"
! grep -q 'test-token-not-real\|FORBIDDEN' "$work/result"
RUNNER_HOME="$work/home" bash "$BOOTSTRAP" --runners-only --runner-repo pneuma-terraformer --plan-runners > "$work/plan"
grep -q 'pneuma-terraformer-contabo would be registered' "$work/plan"
! grep -q 'pneuma-engine\|pneuma-portal' "$work/plan"
# Invalid selection must fail before registering anything.
if RUNNER_HOME="$work/home" bash "$BOOTSTRAP" --runners-only --runner-repo unknown-repo --plan-runners > "$work/invalid" 2>&1; then
  echo 'FAIL unknown runner repo accepted'; exit 1
fi
! grep -q 'would be registered' "$work/invalid"
printf 'PASS runner-only dispatch excludes whole-host provisioning and filters canonical inventory\n'
# Exercise the SAME registration function with fake external boundaries.
# Only names/status markers are persisted; fixture tokens never reach output.
BOOTSTRAP="$BOOTSTRAP" TEST_ROOT="$work" bash -euo pipefail -c '
  source "$BOOTSTRAP"
  RUNNER_HOME="$TEST_ROOT/runners"
  GH_TOKEN="private-fixture-pat"
  RUNNERS="pneuma-terraformer pneuma-terraformer-contabo ci-builder y"
  id() { return 0; }
  usermod() { :; }
  curl() { printf "{\"token\":\"private-fixture-registration\"}\n"; }
  su() {
    local command="${*: -1}"
    case "$command" in
      *"mkdir -p"*) mkdir -p "$dir" ;;
      *"curl -fsSL"*)
        # Rewrite as a tiny fixture; inherited TEST_ROOT is a temporary path.
        printf "#!/bin/sh\nprintf \047svc-%%s\\n\047 \042\0441\042 >> \042\044TEST_ROOT/actions\042\n" > "$dir/svc.sh"
        chmod +x "$dir/svc.sh" ;;
      *"./config.sh"*) printf "configured\n" >> "$TEST_ROOT/actions"; touch "$dir/.runner" ;;
      *) echo "unexpected registration boundary"; exit 95 ;;
    esac
  }
  register_runners
  # Existing identity must skip registration entirely on the second call.
  register_runners
' > "$work/register-output" 2>&1
grep -qx 'configured' "$work/actions"
grep -qx 'svc-install' "$work/actions"
grep -qx 'svc-start' "$work/actions"
test "$(grep -c '^configured$' "$work/actions")" -eq 1
! grep -q 'private-fixture' "$work/register-output"
printf 'PASS shared registration function is idempotent and starts enabled runner without exposing credentials\n'
if BOOTSTRAP="$BOOTSTRAP" TEST_ROOT="$work" bash -euo pipefail -c '
  source "$BOOTSTRAP"
  require_root() { :; }
  hostname() { printf "vmi3131513\n"; }
  register_runners() { echo "FORBIDDEN registration on cluster"; }
  main --runners-only --runner-repo pneuma-terraformer --gh-token-file "$TEST_ROOT/token"
' > "$work/wrong-host" 2>&1; then
  echo 'FAIL runner registration accepted cluster host'; exit 1
fi
! grep -q 'FORBIDDEN registration' "$work/wrong-host"
printf 'PASS runner-only provisioning refuses the cluster host\n'
