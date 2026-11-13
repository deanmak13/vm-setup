#!/usr/bin/env bash
# host/pneuma-gate-tools-install.sh — install the pinned binaries of gate-tools/tools.conf on the build host.
#
#   bash host/pneuma-gate-tools-install.sh gate-tools/tools.conf        (as root, ON THE HOST)
#
# Per line (name version url tarball_sha256 member binary_sha256 destination):
#   1. skip when the destination already has the pinned binary (idempotent);
#   2. download the url (https only; file:// is accepted so the tests can serve a local tarball);
#   3. verify the tarball sha256 BEFORE anything is unpacked;  fail closed, install nothing;
#   4. extract exactly `member` (no other path), verify its sha256 against the pin;
#   5. install it root:root 0755 beside the destination under a dot-name and rename it into place (atomic).
# No `curl | sh`: nothing downloaded is ever executed here. Nothing else on the host is touched.
# --as-user USER chowns to USER instead of root (the tests run unprivileged).
set -euo pipefail

owner=root
if [ "${1:-}" = "--as-user" ]; then owner="${2:?--as-user needs a user}"; shift 2; fi
list="${1:?usage: pneuma-gate-tools-install.sh [--as-user USER] TOOLS_LIST}"
[ -r "$list" ] || { echo "refused: cannot read $list" >&2; exit 2; }
[ "$owner" = root ] && { [ "$(id -u)" -eq 0 ] || { echo "refused: must run as root" >&2; exit 2; }; }

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
fail=0
while read -r name version url tsha member bsha dest extra; do
  case "$name" in ''|'#'*) continue;; esac
  [ -z "${extra:-}" ] || { echo "refused: extra fields on the '$name' line" >&2; fail=1; continue; }
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$version" =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || { echo "refused: bad name/version for '$name'" >&2; fail=1; continue; }
  [[ "$tsha" =~ ^[0-9a-f]{64}$ && "$bsha" =~ ^[0-9a-f]{64}$ ]] || { echo "refused: '$name' needs 64-hex sha256 pins" >&2; fail=1; continue; }
  [[ "$url" =~ ^(https|file):// ]] || { echo "refused: '$name' url must be https" >&2; fail=1; continue; }
  # member: a relative path of plain components; destination: absolute, no '..', and named after the tool
  [[ "$member" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/$member/" != *"/../"* ]] || { echo "refused: '$name' member path '$member'" >&2; fail=1; continue; }
  [[ "$dest" == /* && "$dest" != *..* && "$(basename -- "$dest")" == "$name" ]] || { echo "refused: '$name' destination '$dest' must be an absolute path named $name" >&2; fail=1; continue; }

  if [ -f "$dest" ] && [ ! -L "$dest" ] && [ "$(sha256sum < "$dest" | cut -d' ' -f1)" = "$bsha" ]; then
    echo "$name $version already installed at $dest"; continue
  fi
  tb="$work/$name.tgz"
  if ! curl -fsS --proto '=https,file' --max-time 300 -o "$tb" -- "$url"; then
    echo "refused: cannot download $url" >&2; fail=1; continue
  fi
  got="$(sha256sum < "$tb" | cut -d' ' -f1)"
  if [ "$got" != "$tsha" ]; then
    echo "refused: $name tarball checksum mismatch (want $tsha, got $got): nothing installed" >&2; fail=1; continue
  fi
  ex="$work/$name.x"; mkdir -p "$ex"
  if ! tar -xzf "$tb" -C "$ex" --no-same-owner --no-same-permissions -- "$member" 2>/dev/null || [ ! -f "$ex/$member" ] || [ -L "$ex/$member" ]; then
    echo "refused: $name tarball has no regular file '$member': nothing installed" >&2; fail=1; continue
  fi
  got="$(sha256sum < "$ex/$member" | cut -d' ' -f1)"
  if [ "$got" != "$bsha" ]; then
    echo "refused: $name binary checksum mismatch (want $bsha, got $got): nothing installed" >&2; fail=1; continue
  fi
  tmp="$(mktemp "$(dirname -- "$dest")/.$name.XXXXXX")"
  install -o "$owner" -g "$(id -gn "$owner")" -m 0755 "$ex/$member" "$tmp"
  mv -f -- "$tmp" "$dest"
  echo "$name $version installed at $dest"
done < "$list"
exit "$fail"
