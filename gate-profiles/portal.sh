#!/usr/bin/env bash
# Gate profile: pneuma-portal. Sourced by pneuma-gate-runner (never executed).
# Interface: see gate-profiles/engine.sh.
#
# The gate is the portal's real .githooks/pre-push from the commit under test.
# Its dependencies are one immutable environment per package-lock.json: a node
# toolchain, every node_modules tree produced by `npm ci`, and diff-cover in a
# venv. Each run hard-links those trees into its own checkout (no copy cost, no
# shared writable state: the cache is read-only, so an in-place write fails
# loudly instead of corrupting the next run).

PORTAL_NODE_VERSION="${PNEUMA_GATE_PORTAL_NODE:-22.23.3}"   # ci.yml pins major 22
PORTAL_ENV_SCHEMA=1

profile_cores() { echo "${PNEUMA_GATE_PORTAL_CORES:-2}"; }
profile_mem_mb() { echo "${PNEUMA_GATE_PORTAL_MEM_MB:-6144}"; }

profile_env_key() {
  { cat package-lock.json; printf 'node=%s\nschema=%s\n' "$PORTAL_NODE_VERSION" "$PORTAL_ENV_SCHEMA"; } |
    sha256sum | cut -c1-24
}

profile_env_build() {
  local dir="$1" tarball url sums
  mkdir -p "$dir" || return 1
  tarball="node-v${PORTAL_NODE_VERSION}-linux-x64.tar.xz"
  url="https://nodejs.org/dist/v${PORTAL_NODE_VERSION}"
  ( cd "$dir" &&
    curl -fsSLO "$url/$tarball" && curl -fsSLO "$url/SHASUMS256.txt" &&
    grep " $tarball\$" SHASUMS256.txt | sha256sum -c - >/dev/null &&
    mkdir node && tar -xJf "$tarball" -C node --strip-components=1 &&
    rm -f "$tarball" SHASUMS256.txt ) || return 1
  python3 -m venv "$dir/venv" && "$dir/venv/bin/pip" install -q --disable-pip-version-check diff-cover || return 1
  # npm ci in this run's checkout (lockfile-exact, no scripts beyond the repo's own),
  # then freeze every resulting node_modules tree into the environment.
  PATH="$dir/node/bin:$PATH" npm ci --no-audit --no-fund --loglevel=error || return 1
  local nm
  while IFS= read -r nm; do
    mkdir -p "$dir/trees/$(dirname "$nm")" && cp -a "$nm" "$dir/trees/$nm" || return 1
  done < <(find . -name node_modules -type d -prune -not -path '*/node_modules/*')
}

profile_gate() {
  local envdir="$1" head="$2" base="$3" timeout_s="$4" nm
  while IFS= read -r nm; do
    nm="${nm#"$envdir/trees/"}"
    mkdir -p "$(dirname "$nm")" && cp -al "$envdir/trees/$nm" "$nm" || return 1
  done < <(find "$envdir/trees" -name node_modules -type d -prune)
  printf '[user]\n\tname = pneuma-gate\n\temail = gate@localhost\n' > "$HOME/.gitconfig"
  printf 'refs/heads/gate %s refs/heads/gate %s\n' "$head" "$base" |
    env PATH="$envdir/node/bin:$envdir/venv/bin:$PATH" CI=1 \
      timeout "$timeout_s" nice -n 10 bash .githooks/pre-push
}
