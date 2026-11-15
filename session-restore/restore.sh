#!/usr/bin/env bash
# Recreate tmux sessions/windows from a snapshot and resume each agent session in them.
# Idempotent: a session/window that already exists is skipped, never touched.
# The snapshot is treated as untrusted data: every field is re-validated, and clients are started with tmux's
# argv form (no shell string, no send-keys).
#   restore.sh [--dry-run] [--snapshot FILE] [--socket PATH | --socket-name NAME] [--fallback-cwd DIR]
set -uo pipefail
DIR="${PNEUMA_SESSION_RESTORE_DIR:-$HOME/.cache/pneuma-session-restore}"
SNAP="$DIR/latest.json"
SOCKET="${PNEUMA_TMUX_SOCKET:-}"; SOCKNAME=""
FALLBACK="${PNEUMA_RESTORE_FALLBACK_CWD:-$HOME/Repos/pneuma}"
TOOLS=" ${PNEUMA_RESTORE_TOOLS:-k9s} "
DRY=0; EXPLICIT_SNAP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --snapshot) SNAP="$2"; EXPLICIT_SNAP=1; shift 2 ;;
    --socket) SOCKET="$2"; shift 2 ;;
    --socket-name) SOCKNAME="$2"; shift 2 ;;
    --fallback-cwd) FALLBACK="$2"; shift 2 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null || { echo "restore: jq is required but missing" >&2; exit 1; }
snap_ok() {   # JSON with a panes array, owned by us, not group/world-writable
  local f="${1}" o m
  [ -f "${f}" ] && [ ! -L "${f}" ] || return 1
  read -r o m < <(stat -c '%u %a' -- "${f}")
  if [ "${o}" != "$(id -u)" ] || [ $(( 8#${m} & 8#022 )) -ne 0 ]; then echo "restore: refusing ${f} (must be owned by uid $(id -u) and not group/world-writable; mode ${m} owner ${o})" >&2; return 1; fi
  jq -e '.panes | type == "array"' "${f}" >/dev/null 2>&1
}
if [ "${EXPLICIT_SNAP}" = 1 ]; then snap_ok "${SNAP}" || { echo "restore: snapshot unusable: ${SNAP}" >&2; exit 1; }
elif ! snap_ok "${SNAP}"; then
  echo "restore: ${SNAP} missing/corrupt/unsafe; looking for the newest valid snapshot-*.json" >&2
  found=""; for c in $(ls -1t "${DIR}"/snapshot-*.json 2>/dev/null); do if snap_ok "${c}"; then found="${c}"; break; fi; done
  [ -n "${found}" ] || { echo "restore: no valid snapshot in ${DIR}" >&2; exit 1; }
  echo "restore: FALLBACK to ${found}" >&2; SNAP="${found}"
fi
check_socket() {
  local s="$1" d; d="$(dirname -- "$s")"
  [ ! -L "$d" ] && [ -d "$d" ] && [ "$(stat -c '%u %a' -- "$d")" = "$(id -u) 700" ] || { echo "refusing socket $s: parent dir must be a non-symlink owned by uid $(id -u), mode 0700" >&2; exit 1; }
  [ -S "$s" ] && [ ! -L "$s" ] && [ "$(stat -c %u -- "$s")" = "$(id -u)" ] || { echo "refusing socket $s: not a socket owned by uid $(id -u)" >&2; exit 1; }
}
TM=(tmux)   # default: tmux picks and vets its own socket
if [ -n "$SOCKET" ]; then check_socket "$SOCKET"; TM=(tmux -S "$SOCKET")
elif [ -n "$SOCKNAME" ]; then TM=(tmux -L "$SOCKNAME"); fi
ID_RE='^[0-9a-fA-F-]{8,64}$'; VAL_RE='^[A-Za-z0-9._/@-]+$'; NAME_RE='^[A-Za-z0-9._-]+$'
# valid_argv ARG...: allow-listed client + allow-listed flags only.
valid_argv() {
  local c="$1"; shift
  case "$c" in
    claude) [ "${1:-}" = "--resume" ] && [[ "${2:-}" =~ $ID_RE ]] || return 1; shift 2 ;;
    codex)  [ "${1:-}" = "resume" ] && [[ "${2:-}" =~ $ID_RE ]] || return 1; shift 2 ;;
    *) [[ "$TOOLS" == *" $c "* ]] && [ $# -eq 0 ]; return ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --dangerously-skip-permissions|--dangerously-bypass-approvals-and-sandbox) shift ;;
      --settings|--name) [[ "${2:-}" =~ $VAL_RE ]] || return 1; shift 2 ;;
      *) return 1 ;;
    esac
  done
}
# safe_cwd PATH -> prints PATH if it is an existing dir under $HOME, else nothing.
safe_cwd() { local r; r="$(realpath -e -- "$1" 2>/dev/null)" || return 1; [ -d "$r" ] || return 1; case "$r" in "$HOME"|"$HOME"/*) printf '%s' "$r" ;; *) return 1 ;; esac; }
WRAP="${PNEUMA_RESTORE_SERVER_WRAP:-}"   # prefix for the call that STARTS the tmux server (see systemd unit)
act() {
  if [ "$DRY" = 1 ]; then
    if [ "$1" = new-session ]; then printf '  [plan] %s' "${WRAP:+$WRAP }"; else printf '  [plan] '; fi
    printf '%q ' tmux "$@"; echo; return
  fi
  if [ "$1" = new-session ] && [ -n "$WRAP" ]; then $WRAP "${TM[@]}" "$@"; else "${TM[@]}" "$@"; fi
}
ROWS=(); row() { ROWS+=("$(printf '%-10s %-4s %-18s %-8s %-10s %-9s %s' "$1" "$2" "$3" "$4" "$5" "$6" "$7")"); }
declare -A SEEN_SESSION SEEN_WINDOW HANDLED
BASEIDX="$("${TM[@]}" show-options -gv base-index 2>/dev/null || echo default)"
has_session() { [ -n "${SEEN_SESSION[$1]:-}" ] && return 0; "${TM[@]}" has-session -t "=$1" 2>/dev/null; }
has_window()  { [ -n "${SEEN_WINDOW[$1:$2]:-}" ] && return 0; "${TM[@]}" list-windows -t "=$1" -F '#{window_index}' 2>/dev/null | grep -qx "$2"; }
# Client command in tmux argv form. The login shell supplies PATH; "$@" is the argv, never interpolated into a string.
# The trailing exec keeps an interactive shell in the window if the client exits.
client_cmd() { CMD=(-- bash -lc '"$@"; exec bash -l' _ "$@"); }

while IFS= read -r line; do
  f() { jq -r "$1 // empty" <<<"$line"; }
  sess="$(f .session)"; widx="$(f .window_index)"; wname="$(f .window_name)"; pidx="$(f .pane_index)"
  cwd="$(f .cwd)"; client="$(f .client)"; sid="$(f .session_id)"; conf="$(f .confidence)"
  if ! [[ "$sess" =~ $NAME_RE && "$wname" =~ $NAME_RE && "$widx" =~ ^[0-9]+$ && "$pidx" =~ ^[0-9]+$ ]]; then
    row "?" "?" "(invalid)" "-" "-" "-" "REJECTED: bad session/window name or index"; continue
  fi
  mapfile -t ARGV < <(jq -r '(.launch // [])[]' <<<"$line")
  launch_ok=0; note=""
  if [ ${#ARGV[@]} -gt 0 ]; then
    if valid_argv "${ARGV[@]}"; then launch_ok=1; else note="launch REJECTED (failed validation), plain shell"; echo "  warn: $sess:$widx $note"; fi
  fi
  if where="$(safe_cwd "$cwd")"; then :; else where="$FALLBACK"; note="${note:+$note; }cwd unusable ($cwd) -> fallback $FALLBACK"; echo "  note: $sess:$widx cwd unusable ($cwd), falling back to $FALLBACK"; fi
  CMD=(); [ "$launch_ok" = 1 ] && client_cmd "${ARGV[@]}"
  if [ -z "${HANDLED[$sess:$widx]:-}" ]; then HANDLED[$sess:$widx]=1
    if has_session "$sess"; then
      if has_window "$sess" "$widx"; then row "$sess" "$widx" "$wname" "$client" "${sid: -8}" "$conf" "skipped (window exists)"; continue; fi
      act new-window -d -t "$sess:$widx" -n "$wname" -c "$where" "${CMD[@]}"
    else
      act new-session -d -s "$sess" -n "$wname" -c "$where" "${CMD[@]}"
      SEEN_SESSION[$sess]=1
      if [ "$DRY" = 1 ]; then echo "  [plan] (tmux base-index=$BASEIDX; moves only if it differs from $widx) tmux move-window -s $sess:<first> -t $sess:$widx"
      else cur="$("${TM[@]}" list-windows -t "=$sess" -F '#{window_index}' | head -1)"; [ "$cur" = "$widx" ] || "${TM[@]}" move-window -s "$sess:$cur" -t "$sess:$widx"; fi
    fi
    SEEN_WINDOW[$sess:$widx]=1
  else
    [ -n "${SEEN_WINDOW[$sess:$widx]:-}" ] || { row "$sess" "$widx.$pidx" "$wname" "$client" "${sid: -8}" "$conf" "skipped (window pre-existing)"; continue; }
    act split-window -d -t "$sess:$widx" -c "$where" "${CMD[@]}"
  fi
  if [ "$launch_ok" = 1 ]; then row "$sess" "$widx.$pidx" "$wname" "$client" "${sid: -8}" "${conf:--}" "restored${note:+ ($note)}"
  else snote="$(f .note)"; row "$sess" "$widx.$pidx" "$wname" "$client" "-" "-" "restored as shell${note:+ ($note)}${snote:+ [$snote]}"; fi
done < <(jq -c '.panes | sort_by(.session, .window_index, .pane_index)[]' "$SNAP")
echo; echo "== restore summary ($([ "$DRY" = 1 ] && echo DRY-RUN || echo LIVE)) snapshot=$SNAP =="
printf '%-10s %-4s %-18s %-8s %-10s %-9s %s\n' SESSION WIN NAME CLIENT SESSION-ID CONFIDENCE RESULT
printf '%s\n' "${ROWS[@]}"
echo "Not restored: in-flight subagents/background commands; shell scrollback. Paperclip identities may need re-linking (paperclip-identity skill) if their link file points to a dead pid."
