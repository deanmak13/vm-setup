#!/usr/bin/env bash
# Recreate tmux sessions/windows from a snapshot and resume each agent session in them.
# Idempotent: a session/window that already exists is skipped, never touched.
#   restore.sh [--dry-run] [--snapshot FILE] [--socket PATH] [--fallback-cwd DIR]
set -uo pipefail
DIR="${PNEUMA_SESSION_RESTORE_DIR:-$HOME/.cache/pneuma-session-restore}"
SNAP="$DIR/latest.json"
SOCKET="${PNEUMA_TMUX_SOCKET:-/tmp/tmux-$(id -u)/default}"
FALLBACK="${PNEUMA_RESTORE_FALLBACK_CWD:-$HOME/Repos/pneuma}"
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --snapshot) SNAP="$2"; shift 2 ;;
    --socket) SOCKET="$2"; shift 2 ;;
    --fallback-cwd) FALLBACK="$2"; shift 2 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -f "$SNAP" ] || { echo "restore: snapshot not found: $SNAP" >&2; exit 1; }
T() { tmux -S "$SOCKET" "$@"; }
# PNEUMA_RESTORE_SERVER_WRAP: command prefix for the call that STARTS the tmux server (new-session). The systemd
# unit sets "systemd-run --user --scope --quiet" so the server leaves the oneshot unit's cgroup and survives it.
WRAP="${PNEUMA_RESTORE_SERVER_WRAP:-}"
act() {
  if [ "$DRY" = 1 ]; then
    if [ "$1" = new-session ]; then printf '  [plan] %stmux %s\n' "${WRAP:+$WRAP }" "$*"; else printf '  [plan] tmux %s\n' "$*"; fi
    return
  fi
  if [ "$1" = new-session ] && [ -n "$WRAP" ]; then $WRAP tmux -S "$SOCKET" "$@"; else T "$@"; fi
}
ROWS=()
row() { ROWS+=("$(printf '%-10s %-3s %-18s %-8s %-10s %-9s %s' "$1" "$2" "$3" "$4" "$5" "$6" "$7")"); }
declare -A SEEN_SESSION   # sessions created/planned in this run
declare -A SEEN_WINDOW    # windows created/planned in this run (panes beyond the first attach to them)
has_session() { [ -n "${SEEN_SESSION[$1]:-}" ] && return 0; [ "$DRY" = 0 ] || [ -S "$SOCKET" ] || return 1; T has-session -t "=$1" 2>/dev/null; }
has_window()  { [ -n "${SEEN_WINDOW[$1:$2]:-}" ] && return 0; T list-windows -t "=$1" -F '#{window_index}' 2>/dev/null | grep -qx "$2"; }
MOVED_MSG=""
while IFS=$'\t' read -r sess widx wname pidx cwd client sid conf launch; do
  [ "$launch" = "-" ] && launch=""; [ "$sid" = "-" ] && sid=""
  where="$cwd"; note=""
  if [ ! -d "$cwd" ]; then where="$FALLBACK"; note="cwd gone ($cwd) -> fallback $FALLBACK"; echo "  note: $sess:$widx $note"; fi
  tag="$sess:$widx"
  if [ "$pidx" = 1 ]; then
    if has_session "$sess"; then
      if has_window "$sess" "$widx"; then row "$sess" "$widx" "$wname" "$client" "${sid: -8}" "$conf" "skipped (window exists)"; continue; fi
      act new-window -d -t "$sess:$widx" -n "$wname" -c "$where"
    else
      act new-session -d -s "$sess" -n "$wname" -c "$where"
      SEEN_SESSION[$sess]=1
      # new-session puts its window at base-index; move it to the recorded index if they differ
      if [ "$DRY" = 1 ]; then echo "  [plan] (if base-index != $widx) tmux move-window -s $sess:<first> -t $sess:$widx"
      else cur="$(T list-windows -t "=$sess" -F '#{window_index}' | head -1)"; [ "$cur" = "$widx" ] || T move-window -s "$sess:$cur" -t "$sess:$widx"; fi
    fi
    SEEN_WINDOW[$sess:$widx]=1
    target="$sess:$widx"
  else
    [ -n "${SEEN_WINDOW[$sess:$widx]:-}" ] || { row "$sess" "$widx.$pidx" "$wname" "$client" "${sid: -8}" "$conf" "skipped (window pre-existing)"; continue; }
    act split-window -d -t "$sess:$widx" -c "$where"
    target="$sess:$widx.$pidx"
  fi
  if [ -n "$launch" ]; then
    act send-keys -t "$target" "$launch" Enter
    row "$sess" "$widx.$pidx" "$wname" "$client" "${sid: -8}" "$conf" "restored${note:+ ($note)}"
  else
    row "$sess" "$widx.$pidx" "$wname" "$client" "-" "-" "restored as shell${note:+ ($note)}"
  fi
done < <(jq -r '.panes | sort_by(.session, .window_index, .pane_index)[]
  | [.session,.window_index,.window_name,.pane_index,.cwd,.client,(.session_id//"-"),(.confidence//"-"),(.launch//"-")] | @tsv' "$SNAP" | tr -d '\r')
echo; echo "== restore summary ($([ "$DRY" = 1 ] && echo DRY-RUN || echo LIVE)) snapshot=$SNAP =="
printf '%-10s %-3s %-18s %-8s %-10s %-9s %s\n' SESSION WIN NAME CLIENT SESSION-ID CONFIDENCE RESULT
printf '%s\n' "${ROWS[@]}"
echo "Not restored: in-flight subagents/background commands; k9s/shell scrollback. Paperclip identities must re-link via the paperclip-identity skill if their link file points to a dead pid."
