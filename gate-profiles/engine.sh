#!/usr/bin/env bash
# Gate profile: pneuma-engine. Sourced by pneuma-gate-runner (never executed).
#
# Interface every profile implements (the runner knows nothing repo-specific):
#   profile_cores / profile_mem_mb   admission weight of one gate
#   profile_env_key                  (cwd = checkout) key of the dependency env; same key = same env
#   profile_stage_root <base>        OPTIONAL, runs as root once per env build (assets needing docker)
#   profile_env_build <dir>          (as the gate user) build the env at <dir>; it is frozen read-only after
#   profile_gate <env> <head> <base> <timeout_s>
#                                    run the repo's OWN pre-push hook for that range; exit code = verdict
#
# The gate command is the engine's real .githooks/pre-push, taken from the very
# commit under test, fed the pushed range on stdin exactly as git would.

ENGINE_EXTRAS=(dev mimesis brain gateway)        # = the union the pre-push suites import
ENGINE_ENV_SCHEMA=2                              # bump to force every env to rebuild

profile_cores() { echo "${PNEUMA_GATE_ENGINE_CORES:-2}"; }
profile_mem_mb() { echo "${PNEUMA_GATE_ENGINE_MEM_MB:-3072}"; }

# pneuma-proto is private: its wheels come from the version pyproject floors,
# out of the image already on the host (the same source CI uses), never fetched
# with a token and never copied from a dev box.
_engine_proto_tag() {
  # The dependency manifest is the single source (tools/proto_ref.py reads
  # pyproject's floor); older trees that still pin it in Dockerfiles fall back.
  if [ -f tools/proto_ref.py ]; then python3 tools/proto_ref.py --version; return; fi
  grep -rhoE 'ghcr\.io/deanmak13/pneuma-proto:[0-9]+\.[0-9]+\.[0-9]+' --include=Dockerfile services connectors 2>/dev/null |
    cut -d: -f2 | sort -u
}

profile_env_key() {
  local tag; tag="$(_engine_proto_tag)"
  [ "$(printf '%s\n' "$tag" | grep -c .)" = 1 ] || { echo "expected exactly one proto pin, got [$tag]" >&2; return 1; }
  { cat pyproject.toml; printf 'proto=%s\nschema=%s\nextras=%s\npython=%s\n' \
      "$tag" "$ENGINE_ENV_SCHEMA" "${ENGINE_EXTRAS[*]}" "$(python3 -c 'import sys;print(sys.version_info[:2])')"; } |
    sha256sum | cut -c1-24
}

profile_stage_root() {
  local base="$1" tag dest cid; tag="$(_engine_proto_tag)"
  dest="$base/wheels/pneuma-proto-$tag"
  [ -d "$dest" ] && return 0
  mkdir -p "$dest.partial"
  cid="$(docker create "ghcr.io/deanmak13/pneuma-proto:$tag" /bin/true)" || return 1
  docker cp "$cid":/wheels/. "$dest.partial/" || { docker rm "$cid" >/dev/null; return 1; }
  docker rm "$cid" >/dev/null
  chmod -R a+rX "$dest.partial"; mv "$dest.partial" "$dest"
}

profile_env_build() {
  local dir="$1" tag wheels req
  tag="$(_engine_proto_tag)"; wheels="$PNEUMA_GATE_BASE/wheels/pneuma-proto-$tag"
  req="$(mktemp)"
  # Dependencies only — the project is deliberately NOT installed (an editable
  # install pins imports to whichever checkout built it).
  python3 - "${ENGINE_EXTRAS[@]}" > "$req" <<'PYEOF'
import sys, tomllib
p = tomllib.load(open("pyproject.toml", "rb"))["project"]
reqs = list(p["dependencies"])
for extra in sys.argv[1:]:
    reqs += p["optional-dependencies"][extra]
print("\n".join(dict.fromkeys(reqs)))
PYEOF
  python3 -m venv "$dir/venv" &&
    "$dir/venv/bin/pip" install -q --disable-pip-version-check --find-links "$wheels" -r "$req" grpcio-health-checking ruff
  local rc=$?; rm -f "$req"
  [ "$rc" -eq 0 ] || return "$rc"
  # run_service_unit_tests.sh pip-installs each service's extra_pip packages into
  # the interpreter at gate time. Install them HERE, once, so a run's own
  # (per-run, writable) copy of this env finds them satisfied instead of
  # downloading them on every gate.
  local svc line3 line4
  while IFS= read -r svc; do
    line3="$(python3 tools/ci/detect_changed_services.py gate --service "$svc" --format shell 2>/dev/null | sed -n '3p')"
    line4="$(python3 tools/ci/detect_changed_services.py gate --service "$svc" --format shell 2>/dev/null | sed -n '4p')"
    # shellcheck disable=SC2086
    { [ -z "$line3" ] || "$dir/venv/bin/pip" install -q --disable-pip-version-check --find-links "$wheels" $line3; } || return 1
    # shellcheck disable=SC2086
    { [ -z "$line4" ] || "$dir/venv/bin/pip" install -q --disable-pip-version-check --no-deps $line4; } || return 1
  done < <(python3 - <<'PYEOF'
import sys
sys.path.insert(0, "tools/ci")
try:
    import detect_changed_services as d
    print("\n".join(d.discover_services()))
except Exception:
    pass
PYEOF
)
  return 0
}

# Live Postgres (GATE-PG-1): the live suites need a real PostgreSQL 16 and a gate
# that runs them must not be green without them. A native per-run cluster from the
# host's PG16 binaries, bound to 127.0.0.1 only (asserted, not assumed), random
# port, random password, scram auth, unix socket disabled, stopped on exit. It
# touches nothing docker-, k3s- or volume-shaped.
ENGINE_PG_BIN="${PNEUMA_GATE_PG_BIN:-/usr/lib/postgresql/16/bin}"

_engine_pg_down() {
  [ -n "${_ENGINE_PG_ROOT:-}" ] && "$ENGINE_PG_BIN/pg_ctl" -D "$_ENGINE_PG_ROOT/data" -m immediate -w stop >/dev/null 2>&1
  return 0
}

# Every listener on the cluster's port must be 127.0.0.1. Fails closed when ss is
# missing or when nothing (or anything else) listens there.
_engine_pg_assert_loopback() {  # <port>
  command -v ss >/dev/null 2>&1 || { echo "live-pg: FAILED — ss is needed to prove the cluster binds 127.0.0.1 only" >&2; return 1; }
  local lines listeners bad
  lines="$(ss -H -ltn 2>/dev/null | awk -v p=":$1" '$4 ~ (p "$") {print $4}')"
  listeners="$(printf '%s\n' "$lines" | grep -c .)"
  bad="$(printf '%s\n' "$lines" | grep -vc '^127\.0\.0\.1:' || true)"
  [ "$listeners" -ge 1 ] || { echo "live-pg: FAILED — nothing listens on port $1" >&2; return 1; }
  [ "$bad" = 0 ] || { echo "live-pg: FAILED — the cluster listens beyond 127.0.0.1: $lines" >&2; return 1; }
}

_engine_pg_up() {  # <run dir> — exports INTEGRATION_TEST + PGTEST_DSN; returns 1 on any failure
  local root="$1/pg" port pw
  if [ ! -x "$ENGINE_PG_BIN/initdb" ]; then
    echo "live-pg: FAILED — no PostgreSQL 16 binaries at $ENGINE_PG_BIN; the live suites cannot run, so this gate cannot be green" >&2
    return 1
  fi
  port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')" || return 1
  pw="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
  mkdir -p "$root" && printf '%s' "$pw" > "$root/pw" && chmod 600 "$root/pw" || return 1
  # The postmaster runs inside the gate's systemd scope (see the runner), so the run's
  # MemoryMax covers it. These caps keep its own footprint small for throwaway tests.
  "$ENGINE_PG_BIN/initdb" -D "$root/data" -U gate --pwfile="$root/pw" -A scram-sha-256 -E UTF8 \
    > "$root/initdb.log" 2>&1 || { echo "live-pg: FAILED — initdb (see $root/initdb.log)" >&2; return 1; }
  "$ENGINE_PG_BIN/pg_ctl" -D "$root/data" -l "$root/server.log" -w \
    -o "-p $port -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c fsync=off \
       -c shared_buffers=128MB -c work_mem=4MB -c maintenance_work_mem=64MB -c max_connections=50 -c max_wal_size=256MB" \
    start >/dev/null 2>&1 \
    || { echo "live-pg: FAILED — server did not start (see $root/server.log)" >&2; return 1; }
  _ENGINE_PG_ROOT="$root"
  if ! _engine_pg_assert_loopback "$port"; then _engine_pg_down; return 1; fi
  export INTEGRATION_TEST=1 PGTEST_DSN="postgresql://gate:$pw@127.0.0.1:$port/postgres"
  echo "live-pg: native PostgreSQL 16 on 127.0.0.1:$port (per-run cluster, stopped on exit)"
}

# Arm teardown without clobbering an EXIT handler the caller already set: ours runs
# first, then the previous handler (simple one-line handlers are chained verbatim).
# The live suites are discovered from disk, never listed by hand: every test module
# that calls require_pgtest_dsn() (tools/ci/pgtest_env.py is the definition itself).
_engine_live_modules() {
  git grep -l 'require_pgtest_dsn()' -- '*.py' ':!tools/ci/pgtest_env.py' 2>/dev/null | sort
}

# The verdict on the live junit report, for the modules discovered on disk. Fails when
# there are no modules, when the report is missing or unreadable, when a module ran no
# live test, or when any live test was skipped because the DSN did not arrive.
_engine_live_verdict() {  # <junit.xml> [<module>...]
  python3 - "$@" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

report, modules = sys.argv[1], sys.argv[2:]
if not modules:
    sys.exit("live-pg: FAILED — no live modules found on disk (no require_pgtest_dsn() callers); "
             "with the cluster up that is a fail-open, not a pass")
try:
    root = ET.parse(report).getroot()
except (OSError, ET.ParseError) as exc:
    sys.exit(f"live-pg: FAILED — no readable live junit report at {report}: {exc}")
dotted = {m: m[: -len(".py")].replace("/", ".") for m in modules}
ran = {m: 0 for m in modules}
dsn_skips = []
for case in root.iter("testcase"):
    cls = case.get("classname", "")
    module = next((m for m, d in dotted.items() if cls == d or cls.startswith(d + ".")), None)
    if module is None:
        continue
    skipped = case.find("skipped")
    if skipped is not None:
        if "PGTEST_DSN" in (skipped.get("message") or ""):
            dsn_skips.append(f"{cls}::{case.get('name')}")
        continue
    ran[module] += 1
missing = sorted(m for m, n in ran.items() if n == 0)
if dsn_skips:
    sys.exit(f"live-pg: FAILED — {len(dsn_skips)} live test(s) skipped for a missing PGTEST_DSN with the cluster up: {dsn_skips[:5]}")
if missing:
    sys.exit(f"live-pg: FAILED — live module(s) ran no live test: {missing[:5]}")
print(f"live-pg: {len(modules)} live module(s) ran {sum(ran.values())} live test(s), none skipped for the DSN")
PYEOF
}

# Run the live suites against this run's cluster and judge the junit report.
_engine_run_live() {  # <venv>
  local venv="$1" report="$PNEUMA_GATE_RUN_DIR/live-junit.xml" mods pyrc
  mods="$(_engine_live_modules)"
  if [ -z "$mods" ]; then _engine_live_verdict "$report"; return 1; fi
  # shellcheck disable=SC2086  # the module list is a word list by design
  # Bounded: a hung live suite must fail the gate, not hold the runner's slot forever.
  timeout "${PNEUMA_LIVE_TIMEOUT_S:-900}" "$venv/bin/python" -m pytest $mods -q -p no:cacheprovider \
    --junitxml="$report" > "$PNEUMA_GATE_RUN_DIR/live.log" 2>&1
  pyrc=$?
  cat "$PNEUMA_GATE_RUN_DIR/live.log"
  if [ "$pyrc" = 124 ]; then echo "live-pg: FAILED — the live suites timed out after ${PNEUMA_LIVE_TIMEOUT_S:-900}s" >&2; return 1; fi
  [ "$pyrc" = 0 ] || { echo "live-pg: FAILED — the live suites exited $pyrc" >&2; return 1; }
  # shellcheck disable=SC2086
  _engine_live_verdict "$report" $mods
}

_engine_pg_arm_exit() {
  local prev body
  prev="$(trap -p EXIT)"
  body="$(printf '%s' "$prev" | sed -n "s/^trap -- '\(.*\)' EXIT\$/\1/p")"
  _ENGINE_PREV_EXIT="$body"
  trap '_engine_pg_down; [ -n "$_ENGINE_PREV_EXIT" ] && eval "$_ENGINE_PREV_EXIT"' EXIT
}

profile_gate() {
  local envdir="$1" head="$2" base="$3" timeout_s="$4"
  _engine_pg_up "$PNEUMA_GATE_RUN_DIR" || return 1
  _engine_pg_arm_exit
  # The gate pip-installs INTO its interpreter (editable project + per-service
  # extras), so each run gets its own venv: a hard-linked copy of the frozen
  # cache (instant, no extra disk) with writable directories. Files stay
  # read-only links, so an in-place write fails loudly instead of corrupting
  # the shared cache; pip's unlink-and-recreate works.
  local venv="$PNEUMA_GATE_RUN_DIR/venv"
  cp -al "$envdir/venv" "$venv" && find "$venv" -type d -exec chmod u+w {} + || return 1
  # A scratch identity for tests that create commits; the HOME is per run.
  printf '[user]\n\tname = pneuma-gate\n\temail = gate@localhost\n' > "$HOME/.gitconfig"
  local hook_rc live_rc=0
  printf 'refs/heads/gate %s refs/heads/gate %s\n' "$head" "$base" |
    env PATH="$venv/bin:$PATH" PYTHON="$venv/bin/python" PYTHONDONTWRITEBYTECODE=1 \
        PNEUMA_GATE_LOCK_FILE="$PNEUMA_GATE_RUN_DIR/gate.lock" \
        PNEUMA_PREPUSH_NO_CACHE=1 PNEUMA_PREPUSH_PARALLELISM="$PNEUMA_GATE_CORES" \
      timeout "$timeout_s" nice -n 10 bash .githooks/pre-push
  hook_rc=$?
  # The live suites run against THIS run's cluster and their own junit report is judged.
  _engine_run_live "$venv" || live_rc=1
  [ "$hook_rc" = 0 ] && [ "$live_rc" = 0 ] && return 0
  return 1
}
