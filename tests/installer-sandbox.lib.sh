# tests/installer-sandbox.lib.sh — sourced by the installer tests. Runs a
# host installer (runner-reaper.sh / runner-liveness-check.sh) end to end
# against a throwaway root: every absolute host path is rewritten into
# $SB, the root check is dropped, and systemctl/curl are stubbed. Nothing
# outside the temp dir is touched.
#
#   sandbox_install <installer> <sandbox-dir> [installer args...]
# Leaves the installer's stdout+stderr in $SB/out and returns its exit code.
sandbox_install() {
    local installer=$1 sb=$2; shift 2
    local repo="$sb/repo"
    mkdir -p "$sb/stub" "$repo" "$sb/root" "$sb/etc/systemd/system" "$sb/etc/default" "$sb/etc/logrotate.d" \
        "$sb/usr/local/bin" "$sb/var/lib" "$sb/var/log"
    if [[ ! -d "$repo/bin" ]]; then
        cp -r "$REPO_DIR/bin" "$REPO_DIR/systemd" "$repo/"
    fi
    sed -e "s#/root/#$sb/root/#g" -e "s#/etc/#$sb/etc/#g" -e "s#/usr/local/bin/#$sb/usr/local/bin/#g" \
        -e "s#/var/lib/#$sb/var/lib/#g" -e "s#/var/log/#$sb/var/log/#g" \
        -e 's#^\[\[ \$EUID -eq 0 \]\].*$#true#' "$installer" > "$repo/installer.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/stub/systemctl"
    printf '#!/usr/bin/env bash\nprintf 200\n' > "$sb/stub/curl"
    chmod +x "$sb/stub/"*
    local rc=0
    PATH="$sb/stub:$PATH" bash "$repo/installer.sh" "$@" > "$sb/out" 2>&1 || rc=$?
    return "$rc"
}

# sandbox_digest <sandbox-dir> — one checksum over every file the installer wrote
sandbox_digest() {
    ( cd "$1" && find etc root usr var -type f -print0 | sort -z | xargs -0 sha256sum )
}
